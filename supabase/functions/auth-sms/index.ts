// POST /auth-sms: Supabase Auth's Send SMS hook. Auth texts nothing itself: it calls this with the code
// and we send it through Twilio, in the person's language (profiles.language). The app verifies numbers
// with a phone change (sign-up and You), so the code goes to the new number, and only then.
// Signed with the hook's secret (Standard Webhooks, SEND_SMS_HOOK_SECRET: `v1,whsec_…` from Auth > Hooks).
import { hookError, hookOk, verifyHook } from "../_shared/hook.ts";
import { isAllowedNumber, isRefusedLine, sendSms, verificationSms } from "../_shared/sms.ts";
import { admin } from "../_shared/supabase.ts";
import { language } from "../_shared/texts.ts";

type Payload = {
  user: { id: string; phone?: string; new_phone?: string };
  sms: { otp: string; phone?: string };
};

Deno.serve(async (req) => {
  const payload = await verifyHook<Payload>(req, "SEND_SMS_HOOK_SECRET", "auth-sms");
  if (!payload) return hookError(401, "invalid signature");

  const { user, sms } = payload;
  // Only to verify a number on a signed-in account (a phone change: `new_phone` is set). Never a code to
  // log in or sign up with a phone: drafft accounts are email ones, whatever Auth's Phone provider allows.
  if (!user.new_phone) {
    console.warn("auth-sms: not a phone change, not sent");
    return hookError(403, "Phone sign-in isn't available.");
  }
  // Where to send: `sms.phone`; on a phone change the new number is also in `user.new_phone` (`user.phone`
  // is still the old one, or empty the first time).
  const raw = sms.phone || user.new_phone || user.phone || "";
  const to = raw.startsWith("+") ? raw : `+${raw}`;
  if (!isAllowedNumber(to)) {
    console.warn(`auth-sms: ${to.slice(0, 4)}… not in the allowed countries`);
    return hookError(400, "This number can't receive codes.");
  }
  // Virtual and VoIP numbers: same answer, so it doesn't say what was checked.
  if (await isRefusedLine(to)) {
    console.warn(`auth-sms: ${to.slice(0, 4)}… refused line type`);
    return hookError(400, "This number can't receive codes.");
  }

  try {
    const { data: profile } = await admin.from("profiles").select("language").eq("id", user.id).maybeSingle();
    const lang = language(profile?.language);
    await sendSms(to, verificationSms(lang, sms.otp));
    console.log(`auth-sms: ${to.slice(0, 4)}… ${lang}`);
    return hookOk();
  } catch (error) {
    console.error("auth-sms", error);
    return hookError(500, "SMS not sent");
  }
});
