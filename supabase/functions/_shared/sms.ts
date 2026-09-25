// The verification SMS, in the app's languages (same register as texts.ts). Short on purpose: under 70
// characters it stays one SMS even when an accent switches it to Unicode, and iOS finds the code in it
// to offer it above the keyboard.
import { env, optionalEnv } from "./env.ts";
import type { Language } from "./texts.ts";

const verification: Record<Language, (code: string) => string> = {
  en: (c) => `Your drafft code: ${c}. Don't share it with anyone.`,
  fr: (c) => `Ton code drafft : ${c}. Ne le partage avec personne.`,
  es: (c) => `Tu código de drafft: ${c}. No lo compartas con nadie.`,
  de: (c) => `Dein drafft-Code: ${c}. Teile ihn mit niemandem.`,
  it: (c) => `Il tuo codice drafft: ${c}. Non condividerlo con nessuno.`,
  pt: (c) => `O teu código drafft: ${c}. Não o partilhes com ninguém.`,
  nl: (c) => `Je drafft-code: ${c}. Deel hem met niemand.`,
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
