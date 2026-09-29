// The verification SMS, in the app's languages. Apple's documented shape ("Your Example code is 123456"):
// the code last, nothing after it, so iOS offers it above the keyboard. The brand is in every language: the
// sender is "drafft" only where alphanumeric senders are allowed, a number elsewhere. Short, so it stays one
// SMS even when an accent switches it to Unicode.
import { env, optionalEnv } from "./env.ts";
import type { Language } from "./texts.ts";
import { checkResponse, viaProvider } from "./providers.ts";

export const verification: Record<Language, (code: string) => string> = {
  en: (c) => `Your drafft code is ${c}`,
  fr: (c) => `Ton code drafft est ${c}`,
  es: (c) => `Tu código de drafft es ${c}`,
  de: (c) => `Dein drafft-Code ist ${c}`,
  it: (c) => `Il tuo codice drafft è ${c}`,
  pt: (c) => `O teu código drafft é ${c}`,
  nl: (c) => `Je drafft-code is ${c}`,
};

export function verificationSms(lang: Language, code: string): string {
  return verification[lang](code);
}

/** A verification number: E.164, any country. Which lines get a code is Twilio Lookup's answer. */
export function isE164(value: string): boolean {
  return /^\+[1-9]\d{6,14}$/.test(value);
}

/** The only line type that gets a code: a mobile line. Everything else is refused, `unknown` and a
 * missing type included: premium and shared-cost numbers (SMS pumping), virtual and VoIP numbers (made in
 * seconds, the usual way back after a ban), and lines that can't take an SMS anyway. */
const acceptedLineTypes = new Set(["mobile"]);

/** What Lookup says about a number: `ok` (a mobile line), `invalid` (not a real number), `refused` (any
 * other line type), `unavailable` (Lookup down, too slow or not configured on a hosted project). */
export type LineCheck = "ok" | "invalid" | "refused" | "unavailable";

export interface LookupOptions {
  /** TWILIO_LOOKUP_API_KEY_SID and _SECRET: Lookup runs in Twilio's US1 region, with its own US1 key. */
  sid: string | undefined;
  secret: string | undefined;
  /** SUPABASE_URL: https means a hosted project, where a missing key fails closed. */
  supabaseUrl: string;
  fetch?: typeof fetch;
}

/** Twilio Lookup v2 (Line Type Intelligence, a few cents each), before every verification SMS. It fails
 * closed: without an answer, no code goes out. Only locally (no key, not https) is it skipped. */
export async function checkLine(e164: string, options: LookupOptions): Promise<LineCheck> {
  if (!options.sid || !options.secret) {
    if (options.supabaseUrl.startsWith("https://")) {
      console.error("twilio lookup: TWILIO_LOOKUP_API_KEY_SID/_SECRET not set, verification SMS refused");
      return "unavailable";
    }
    console.warn("twilio lookup: no key, line check skipped (local only)");
    return "ok";
  }
  try {
    const res = await (options.fetch ?? fetch)(
      `https://lookups.twilio.com/v2/PhoneNumbers/${encodeURIComponent(e164)}?Fields=line_type_intelligence`,
      {
        headers: { authorization: `Basic ${btoa(`${options.sid}:${options.secret}`)}` },
        signal: AbortSignal.timeout(4000),
      },
    );
    // Lookup answers 404 for a number it can't parse at all.
    if (res.status === 404) {
      await res.body?.cancel();
      return "invalid";
    }
    if (!res.ok) throw new Error(`lookup ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = await res.json() as {
      valid?: boolean;
      line_type_intelligence?: { type?: string | null; error_code?: number | null } | null;
    };
    if (body.valid === false) return "invalid";
    const lti = body.line_type_intelligence;
    // Lookup answered, but without the line type (its own error): nothing known, so nothing sent.
    if (!lti || lti.error_code) {
      console.error("twilio lookup: no line type", lti?.error_code);
      return "unavailable";
    }
    return acceptedLineTypes.has(lti.type ?? "") ? "ok" : "refused";
  } catch (error) {
    console.error("twilio lookup", error);
    return "unavailable";
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
  await viaProvider("twilio", async () => {
    const res = await fetch(`https://${host}/2010-04-01/Accounts/${account}/Messages.json`, {
      method: "POST",
      signal: AbortSignal.timeout(10_000),
      headers: { authorization: `Basic ${auth}`, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ To: to, Body: body, MessagingServiceSid: env("TWILIO_MESSAGING_SERVICE_SID") }),
    });
    await checkResponse("twilio", res, "twilio");
  });
}
