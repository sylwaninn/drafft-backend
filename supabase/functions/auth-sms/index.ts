// POST /auth-sms: Supabase Auth's Send SMS hook. Auth texts nothing itself: it calls this with the code
// and we send it through Twilio, in the person's language (profiles.language). The app verifies numbers
// with a phone change (sign-up and You) asked through the phone-code function, which checks the account,
// the limits and the line first (_shared/phone_code.ts). Here, the code goes out only once the account's
// email is confirmed (`email_unconfirmed`), and only to a number with an approved reservation for that
// account (`sms_not_reserved`): a phone change asked of Auth directly gets no SMS.
// Signed with the hook's secret (Standard Webhooks, SEND_SMS_HOOK_SECRET: `v1,whsec_…` from Auth > Hooks).
import { hookError, hookOk, verifyHook } from "../_shared/hook.ts";
import { smsHookDecision, type SmsHookPayload } from "../_shared/phone_code.ts";
import { sendSms, verificationSms } from "../_shared/sms.ts";
import { admin } from "../_shared/supabase.ts";
import { language } from "../_shared/texts.ts";
import { ProviderError } from "../_shared/providers.ts";

Deno.serve(async (req) => {
  const payload = await verifyHook<SmsHookPayload>(req, "SEND_SMS_HOOK_SECRET", "auth-sms");
  if (!payload) return hookError(401, "invalid signature");

  try {
    const decision = await smsHookDecision(payload, {
      emailConfirmed: async (id) => {
        const { data, error } = await admin.auth.admin.getUserById(id);
        if (error) throw new Error(`user: ${error.message}`);
        return Boolean(data.user?.email_confirmed_at);
      },
      consume: async (id, phone) => {
        const { data, error } = await admin.rpc("consume_sms", { p_user: id, p_phone: phone });
        if (error) throw new Error(`consume_sms: ${error.message}`);
        return data === true;
      },
    });
    if (!decision.send) {
      console.warn(`auth-sms: not sent, ${decision.log}`);
      return hookError(decision.status, decision.message);
    }

    const { data: profile } = await admin.from("profiles").select("language").eq("id", payload.user.id)
      .maybeSingle();
    const lang = language(profile?.language);
    await sendSms(decision.to, verificationSms(lang, payload.sms.otp));
    console.log(`auth-sms: ${decision.to.slice(0, 4)}… ${lang}`);
    await reportTwilio(true);
    return hookOk();
  } catch (error) {
    console.error("auth-sms", error);
    // Twilio down (not a refused number): its circuit hears it, and the outbox alerts the team.
    if (error instanceof ProviderError && error.provider === "twilio" && error.transient) {
      await reportTwilio(false, String(error).slice(0, 300));
    }
    return hookError(500, "SMS not sent");
  }
});

/** Twilio's circuit breaker (private.provider_circuits). Never fails the hook. */
async function reportTwilio(ok: boolean, error?: string) {
  const { error: failed } = await admin.rpc("provider_report", {
    p_provider: "twilio",
    p_ok: ok,
    p_error: error ?? null,
  });
  if (failed) console.warn(`auth-sms: circuit report failed: ${failed.message}`);
}
