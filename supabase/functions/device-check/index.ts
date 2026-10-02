// POST /device-check { token, environment, platform? } → 204
// The iPhone app sends a fresh DeviceCheck token at each launch and sign-in (never on the Simulator). Apple's
// environment is the project's (DEVICECHECK_ENVIRONMENT): the app's `environment` is only logged when it
// differs, so a client can't steer its token to the other Apple environment. The token
// is kept for db-events, which sets the iPhone's bits when a hold changes. An account closed or on hold
// opening the app sets them again; a new account on an iPhone where one was closed goes to review, on one
// where an account is on hold owes a selfie, once.
// The Android app (`platform: "android"`) sends a Play Integrity token instead: checked with Google before it
// is stored, it reads and writes Device recall, which plays the part of the two bits (_shared/playintegrity.ts).
// The answer never says what was found.
import { deviceCheckConfigured, deviceCheckEnvironment, queryBits, updateBits } from "../_shared/devicecheck.ts";
import { HttpError, readJson, serve } from "../_shared/http.ts";
import { packageName, playIntegrityConfigured, verify, writeBits } from "../_shared/playintegrity.ts";
import { admin, check, must, requireUser } from "../_shared/supabase.ts";

/** A Play Integrity token, once verified: stored, then the account's standing decides what happens to the bits. */
async function androidCheck(userId: string, token: string): Promise<Response> {
  const done = new Response(null, { status: 204 });
  if (!playIntegrityConfigured()) {
    console.warn(`device-check: Play Integrity not configured, android token skipped for ${userId}`);
    return done;
  }
  let verdict;
  try {
    verdict = await verify(token, userId);
  } catch (error) {
    // Google down, or a token it refuses (expired, other project): the next launch sends a fresh one.
    console.error(`device-check: Play Integrity could not read the token of ${userId} (${packageName()})`, error);
    return done;
  }
  if (!verdict.ok) {
    // A modified app or phone, an emulator, a sideloaded build, a replayed token: nothing is kept, nothing said.
    console.warn(`device-check: ${userId} android token refused (${verdict.reason})`);
    return done;
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
  try {
    if (next === "ban" && !verdict.bits.bit0) {
      await writeBits(token, { bit0: true });
    } else if (next === "hold" && !verdict.bits.bit1) {
      await writeBits(token, { bit1: true });
    } else if (next === "check" && (verdict.bits.bit0 || verdict.bits.bit1)) {
      check(
        await admin.rpc("device_flagged", { p_user: userId, p_closed: verdict.bits.bit0, p_held: verdict.bits.bit1 }),
        "device flagged",
      );
      console.log(`device-check: ${userId} on a flagged android device (${verdict.bits.bit0 ? "closed" : "held"})`);
    }
  } catch (error) {
    console.error(`device-check: Play Integrity refused ${next} for ${userId}`, error);
  }
  return done;
}

serve(async (req) => {
  const user = await requireUser(req);
  const { token, environment, platform } = await readJson<
    { token?: unknown; environment?: unknown; platform?: unknown }
  >(req);
  const android = platform === "android";
  if (typeof token !== "string" || token.length < 20 || token.length > (android ? 16384 : 8192)) {
    throw new HttpError(400, "invalid_token");
  }
  if (android) return await androidCheck(user.id, token);
  const env = deviceCheckEnvironment();
  if (environment !== undefined && environment !== env) {
    // A development build on a production project (or the reverse): Apple will refuse its token.
    console.warn(`device-check: ${user.id} sent a ${String(environment).slice(0, 20)} token, ${env} used`);
  }
  const next = must(
    await admin.rpc("record_device_check", { p_user: user.id, p_token: token, p_environment: env }),
    "record device check",
  ) as string;

  if (next === "none") return new Response(null, { status: 204 });
  if (!deviceCheckConfigured()) {
    console.warn(`device-check: Apple DeviceCheck not configured, ${next} skipped for ${user.id}`);
    return new Response(null, { status: 204 });
  }
  try {
    if (next === "ban") {
      await updateBits(token, env, { bit0: true });
    } else if (next === "hold") {
      await updateBits(token, env, { bit1: true });
    } else {
      const bits = await queryBits(token, env);
      if (bits.bit0 || bits.bit1) {
        check(
          await admin.rpc("device_flagged", { p_user: user.id, p_closed: bits.bit0, p_held: bits.bit1 }),
          "device flagged",
        );
        console.log(`device-check: ${user.id} on a flagged iPhone (${bits.bit0 ? "closed" : "held"})`);
      }
    }
  } catch (error) {
    // Apple down, a stale token or one from the other environment: the next launch sends a fresh one.
    // Never block the person on it, but keep Apple's answer in the logs.
    console.error(`device-check: Apple refused ${next} for ${user.id} (${env})`, error);
  }
  return new Response(null, { status: 204 });
});
