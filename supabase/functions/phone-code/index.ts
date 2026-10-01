// POST /phone-code { phone } → {}: texts a 6-digit code to verify a phone number (sign-up and You), as
// the signed-in person. The app then checks it with Auth (verifyOTP, type phone_change). The checks, in
// order, and their stable codes: _shared/phone_code.ts. Limits: reserve_sms (per number, account and IP).
import { env, optionalEnv } from "../_shared/env.ts";
import { HttpError, json, readJson, serve } from "../_shared/http.ts";
import { requestPhoneCode } from "../_shared/phone_code.ts";
import { checkLine } from "../_shared/sms.ts";
import { admin, secretKey } from "../_shared/supabase.ts";
import { requestIp } from "../_shared/turnstile.ts";

serve(async (req) => {
  const body = await readJson<{ phone?: unknown }>(req);
  const jwt = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!jwt) throw new HttpError(401, "unauthenticated");
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data.user) throw new HttpError(401, "unauthenticated");

  await requestPhoneCode(data.user, body.phone, requestIp(req), {
    reserve: async (userId, phone, ip) => {
      const { data, error } = await admin.rpc("reserve_sms", { p_user: userId, p_phone: phone, p_ip: ip ?? null });
      if (error?.hint === "sms_limit") throw new HttpError(429, "sms_limit");
      if (error?.hint === "phone_invalid") throw new HttpError(400, "phone_invalid");
      if (error) throw new Error(`reserve_sms: ${error.message}`);
      return data as number;
    },
    approve: async (id) => {
      const { error } = await admin.rpc("approve_sms", { p_id: id });
      if (error) throw new Error(`approve_sms: ${error.message}`);
    },
    checkLine: (phone) =>
      checkLine(phone, {
        sid: optionalEnv("TWILIO_LOOKUP_API_KEY_SID"),
        secret: optionalEnv("TWILIO_LOOKUP_API_KEY_SECRET"),
        supabaseUrl: env("SUPABASE_URL"),
      }),
    startPhoneChange: async (phone) => {
      const res = await fetch(`${env("SUPABASE_URL")}/auth/v1/user`, {
        method: "PUT",
        headers: { apikey: secretKey(), authorization: `Bearer ${jwt}`, "content-type": "application/json" },
        body: JSON.stringify({ phone }),
      });
      const answer = await res.json().catch(() => ({})) as { error_code?: string; hint?: string };
      return { status: res.status, errorCode: answer.error_code, hint: answer.hint };
    },
  });
  return json({});
});
