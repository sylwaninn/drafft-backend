// The verification SMS, from the app's request to Auth's Send SMS hook. Every code goes through
// requestPhoneCode (the phone-code function), in this order, each step refusing with a stable code:
//
//   1. the account's email is confirmed          email_unconfirmed (403)
//   2. the number is E.164                       phone_invalid (400)
//   3. the send is reserved under the limits     sms_limit (429), per number, account and IP (reserve_sms)
//   4. Twilio Lookup says it's a mobile line     phone_invalid (400), phone_unsupported (400),
//                                                phone_check_unavailable (503, fails closed)
//   5. Auth starts the phone change              phone_taken (409), sms_limit (429), sms_failed (502)
//
// Auth then calls the hook (auth-sms), which sends only for an approved reservation of that account and
// number (smsHookDecision): a phone change asked of Auth directly gets no SMS.
import { HttpError } from "./http.ts";
import { isE164, type LineCheck } from "./sms.ts";

export interface PhoneCodeUser {
  id: string;
  email_confirmed_at?: string | null;
}

export interface PhoneCodeDeps {
  /** reserve_sms: the reservation's id; throws HttpError(429, "sms_limit") past a limit. */
  reserve(userId: string, phone: string, ip: string | undefined): Promise<number>;
  /** approve_sms: Lookup accepted the line. */
  approve(id: number): Promise<void>;
  checkLine(phone: string): Promise<LineCheck>;
  /** Auth's phone change, as the person (PUT /auth/v1/user): Auth generates the code and calls the hook.
   * `hint`: a database refusal's code (a number a banned account used is `phone_taken`). */
  startPhoneChange(phone: string): Promise<{ status: number; errorCode?: string; hint?: string }>;
}

export async function requestPhoneCode(
  user: PhoneCodeUser,
  rawPhone: unknown,
  ip: string | undefined,
  deps: PhoneCodeDeps,
): Promise<void> {
  if (!user.email_confirmed_at) throw new HttpError(403, "email_unconfirmed");
  const phone = typeof rawPhone === "string" ? rawPhone.trim() : "";
  if (!isE164(phone)) throw new HttpError(400, "phone_invalid");

  const reservation = await deps.reserve(user.id, phone, ip);
  switch (await deps.checkLine(phone)) {
    case "ok":
      break;
    case "invalid":
      throw new HttpError(400, "phone_invalid");
    case "refused":
      throw new HttpError(400, "phone_unsupported");
    case "unavailable":
      throw new HttpError(503, "phone_check_unavailable");
  }
  await deps.approve(reservation);

  const { status, errorCode, hint } = await deps.startPhoneChange(phone);
  if (status >= 200 && status < 300) return;
  if (errorCode === "phone_exists" || hint === "phone_taken") throw new HttpError(409, "phone_taken");
  if (status === 429 || errorCode?.startsWith("over_")) throw new HttpError(429, "sms_limit");
  console.error(`phone-code: auth answered ${status} ${errorCode ?? ""}`);
  throw new HttpError(502, "sms_failed");
}

export type SmsHookDecision =
  | { send: true; to: string }
  | { send: false; status: number; message: string; log: string };

export interface SmsHookPayload {
  user: { id: string; phone?: string; new_phone?: string; email_confirmed_at?: string | null };
  sms: { otp: string; phone?: string };
}

/** The hook's rules, before anything is texted. `emailConfirmed` reads the account when the payload
 * doesn't say (fails closed); `consume` takes the approved reservation (consume_sms). */
export async function smsHookDecision(
  payload: SmsHookPayload,
  deps: { emailConfirmed(userId: string): Promise<boolean>; consume(userId: string, phone: string): Promise<boolean> },
): Promise<SmsHookDecision> {
  const { user, sms } = payload;
  // Only to verify a number on a signed-in account (a phone change: `new_phone` is set). Never a code to
  // log in or sign up with a phone: drafft accounts are email ones, whatever Auth's Phone provider allows.
  if (!user.new_phone) {
    return { send: false, status: 403, message: "Phone sign-in isn't available.", log: "not a phone change" };
  }
  const confirmed = user.email_confirmed_at ? true : await deps.emailConfirmed(user.id);
  if (!confirmed) return { send: false, status: 403, message: "email_unconfirmed", log: "email not confirmed" };

  // Where to send: `sms.phone`; on a phone change the new number is also in `user.new_phone` (`user.phone`
  // is still the old one, or empty the first time). Auth keeps numbers without the "+".
  const raw = sms.phone || user.new_phone;
  const to = raw.startsWith("+") ? raw : `+${raw}`;
  if (!isE164(to) || !(await deps.consume(user.id, to))) {
    return { send: false, status: 403, message: "sms_not_reserved", log: "no approved reservation" };
  }
  return { send: true, to };
}
