// The Android half of device-check: a Play Integrity token, checked with Google before it is stored
// (_shared/playintegrity.ts). The answer is always a bare 204: it never says what was found.
import type { BitChange, DeviceBits } from "../_shared/devicebits.ts";
import { env } from "../_shared/env.ts";
import { HttpError } from "../_shared/http.ts";
import {
  PlayApiError,
  PlayAuthError,
  playIntegrityConfigured,
  type Verdict,
  verify,
  writeBits,
} from "../_shared/playintegrity.ts";
import { admin, check, must } from "../_shared/supabase.ts";

/** An account in good standing whose Android token was verified within this long isn't decoded again. */
const SKIP_WINDOW_MS = 24 * 60 * 60 * 1000;

export function noContent(): Response {
  return new Response(null, { status: 204 });
}

/** An account's bits were set by another one on this device: review or selfie, once (device_flagged). */
export async function flagDevice(userId: string, bits: DeviceBits, device: "iPhone" | "android device") {
  check(
    await admin.rpc("device_flagged", { p_user: userId, p_closed: bits.bit0, p_held: bits.bit1 }),
    "device flagged",
  );
  console.log(`device-check: ${userId} on a flagged ${device} (${bits.bit0 ? "closed" : "held"})`);
}

type Begin = { standing: "ok" | "held" | "banned"; verified_at: string | null; has_pending: boolean };

/**
 * A Play Integrity token: counted (an account may check 20 times an hour), verified, stored, then the account's
 * standing decides what happens to the device's bits.
 *   - closed or on hold: the bit is set, together with any change that waited for a verified token;
 *   - in good standing and never flagged: the bits are read, and another account's mark flags this one;
 *   - a refused token (a modified app or phone, an emulator, a sideloaded build, a token made for another
 *     account) is never stored and writes nothing. For a closed or held account that is an evasion signal,
 *     so the log says so at error level.
 */
export async function androidCheck(userId: string, token: string, now = Date.now()): Promise<Response> {
  if (!playIntegrityConfigured()) {
    // A hosted project without its secrets has the whole Android check off: loud there, quiet locally.
    const log = env("SUPABASE_URL").startsWith("https://") ? console.error : console.warn;
    log(`device-check: Play Integrity not configured, android token skipped for ${userId}`);
    return noContent();
  }

  const began = await admin.rpc("device_check_begin", { p_user: userId });
  if (began.error?.hint === "too_many_requests") throw new HttpError(429, "too_many_requests");
  const [state] = must(began, "device check begin") as Begin[];
  const verifiedAt = state.verified_at ? Date.parse(state.verified_at) : NaN;
  // Saves Google's daily decode quota: nothing to set, nothing waiting, and read recently.
  if (state.standing === "ok" && !state.has_pending && now - verifiedAt < SKIP_WINDOW_MS) return noContent();

  let verdict: Verdict;
  try {
    verdict = await verify(token, userId, now);
  } catch (error) {
    // A 4xx on the decode is a client token Google refuses (expired, other project): the next opening sends a
    // new one. Everything else is ours (credentials, permission, quota, Google down, a timeout) and turns the
    // Android check off for everyone until it is fixed.
    const clientFault = error instanceof PlayApiError && error.step === "decode" && error.status >= 400 &&
      error.status < 500 && ![401, 403, 429].includes(error.status);
    if (clientFault) console.warn(`device-check: ${userId} android token refused by Google: ${error.message}`);
    else {
      const kind = error instanceof PlayAuthError ? "credentials" : "Google";
      console.error(`device-check: Play Integrity ${kind} failure, ${userId} not checked`, error);
    }
    return noContent();
  }
  if (!verdict.ok) {
    const why = `${verdict.reason}${verdict.detail ? `, ${verdict.detail}` : ""}`;
    if (state.standing === "ok") console.warn(`device-check: ${userId} android token refused (${why})`);
    else {
      console.error(
        `device-check: ${userId} is ${state.standing} and sent an android token refused (${why}): no bit written`,
      );
    }
    return noContent();
  }

  const next = must(
    await admin.rpc("record_device_check", {
      p_user: userId,
      p_token: token,
      p_environment: "production",
      p_platform: "android",
    }),
    "record device check",
  ) as string;

  let step = "take pending";
  const pending: BitChange = {};
  try {
    const [taken] = must(await admin.rpc("device_check_take_pending", { p_user: userId }), "take pending") as {
      bit0: boolean | null;
      bit1: boolean | null;
    }[];
    if (taken.bit0 !== null) pending.bit0 = taken.bit0;
    if (taken.bit1 !== null) pending.bit1 = taken.bit1;
    const waited = Object.keys(pending).length > 0;

    // The account's standing decides its own bit; what waited covers the bits it no longer owns. What the
    // device already says needs no write.
    const change: BitChange = { ...pending };
    if (next === "ban") change.bit0 = true;
    else if (next === "hold") change.bit1 = true;
    if (change.bit0 === verdict.bits.bit0) delete change.bit0;
    if (change.bit1 === verdict.bits.bit1) delete change.bit1;
    if (Object.keys(change).length > 0) {
      step = "write";
      await writeBits(token, change);
    }

    // Bits read with a waiting clear may be this account's own: read them at the next opening instead.
    if (next === "check" && !waited && (verdict.bits.bit0 || verdict.bits.bit1)) {
      step = "flag";
      await flagDevice(userId, verdict.bits, "android device");
    }
  } catch (error) {
    console.error(`device-check: ${userId} android ${next}: ${step} failed`, error);
    if (step === "write" && Object.keys(pending).length > 0) {
      // Put back what was taken: the next verified token applies it.
      const back = await admin.rpc("device_check_set_pending", {
        p_user: userId,
        p_bit0: pending.bit0 ?? null,
        p_bit1: pending.bit1 ?? null,
      });
      if (back.error) console.error(`device-check: ${userId} waiting bits lost: ${back.error.message}`);
    }
  }
  return noContent();
}
