// The verification SMS, in the app's languages. Apple's documented shape ("Your Example code is 123456"):
// the code last, nothing after it, so iOS offers it above the keyboard. The sender "drafft" names the app.
// Short, so it stays one SMS even when an accent switches it to Unicode.
import { env, optionalEnv } from "./env.ts";
import type { Language } from "./texts.ts";

const verification: Record<Language, (code: string) => string> = {
  en: (c) => `Your drafft code is ${c}`,
  fr: (c) => `Ton code de vérification est ${c}`,
  es: (c) => `Tu código de verificación es ${c}`,
  de: (c) => `Dein Bestätigungscode ist ${c}`,
  it: (c) => `Il tuo codice di verifica è ${c}`,
  pt: (c) => `O teu código de verificação é ${c}`,
  nl: (c) => `Je verificatiecode is ${c}`,
};

export function verificationSms(lang: Language, code: string): string {
  return verification[lang](code);
}

/** The countries the app offers at the phone step (PhoneCountry.all): nothing else is texted, so a bot
 * can't run up the bill on premium numbers elsewhere. Twilio's geo permissions say the same. */
const allowedPrefixes = ["+33", "+32", "+41", "+352", "+44", "+34", "+39", "+49", "+1"];

export function isAllowedNumber(e164: string): boolean {
  return /^\+[1-9]\d{6,14}$/.test(e164) && allowedPrefixes.some((p) => e164.startsWith(p));
}

/** Lines that never get a code: virtual and VoIP numbers (made in seconds, the usual way back after a
 * ban), and lines that can't take an SMS anyway. */
const refusedLineTypes = new Set([
  "nonFixedVoip",
  "fixedVoip",
  "tollFree",
  "premium",
  "sharedCost",
  "uan",
  "voicemail",
  "pager",
  "landline",
]);

/** Twilio Lookup v2 (Line Type Intelligence, a few cents each), only at a phone verification. Lookup
 * runs in Twilio's US1 region, so it has its own US1 API key (TWILIO_LOOKUP_API_KEY_SID and _SECRET).
 * Unset (locally), unknown type, or Lookup down: the code goes out; this filters, it doesn't gate. */
export async function isRefusedLine(e164: string): Promise<boolean> {
  const sid = optionalEnv("TWILIO_LOOKUP_API_KEY_SID"), secret = optionalEnv("TWILIO_LOOKUP_API_KEY_SECRET");
  if (!sid || !secret) return false;
  try {
    const res = await fetch(
      `https://lookups.twilio.com/v2/PhoneNumbers/${encodeURIComponent(e164)}?Fields=line_type_intelligence`,
      { headers: { authorization: `Basic ${btoa(`${sid}:${secret}`)}` }, signal: AbortSignal.timeout(4000) },
    );
    if (!res.ok) throw new Error(`lookup ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = await res.json() as { line_type_intelligence?: { type?: string | null } | null };
    return refusedLineTypes.has(body.line_type_intelligence?.type ?? "");
  } catch (error) {
    console.error("twilio lookup", error);
    return false;
  }
}

const regionHosts: Record<string, string> = {
  us1: "api.twilio.com",
  ie1: "api.dublin.ie1.twilio.com",
  au1: "api.sydney.au1.twilio.com",
};

/** Hosted: Twilio, through a Messaging Service (sender "drafft" where allowed, a number elsewhere).
 * Local: MAILPIT_URL set, the SMS lands in Mailpit as an email and no phone is texted, unless
 * SMS_REAL=true in .env.local sends it through Twilio to try it on a real phone. */
export async function sendSms(to: string, body: string): Promise<void> {
  const mailpit = optionalEnv("SMS_REAL") === "true" ? undefined : optionalEnv("MAILPIT_URL");
  if (mailpit) {
    const res = await fetch(`${mailpit}/api/v1/send`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        From: { Email: "sms@drafft.local", Name: "drafft SMS" },
        To: [{ Email: `${to.replace("+", "")}@sms.drafft.local` }],
        Subject: `SMS to ${to}`,
        Text: body,
      }),
    });
    if (!res.ok) throw new Error(`mailpit ${res.status}: ${await res.text()}`);
    return;
  }

  const account = env("TWILIO_ACCOUNT_SID");
  // An API key (SK…) rather than the account's auth token: it can be revoked on its own.
  const auth = btoa(`${env("TWILIO_API_KEY_SID")}:${env("TWILIO_API_KEY_SECRET")}`);
  // Ireland (ie1) by default: drafft's Twilio keys and Messaging Service live there, next to its EU users.
  // TWILIO_REGION overrides it (us1, au1). A key and a service only work on their own region's host.
  const host = regionHosts[(optionalEnv("TWILIO_REGION") ?? "ie1").toLowerCase()] ?? regionHosts.ie1;
  const res = await fetch(`https://${host}/2010-04-01/Accounts/${account}/Messages.json`, {
    method: "POST",
    headers: { authorization: `Basic ${auth}`, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ To: to, Body: body, MessagingServiceSid: env("TWILIO_MESSAGING_SERVICE_SID") }),
  });
  if (!res.ok) throw new Error(`twilio ${res.status}: ${await res.text()}`);
}
