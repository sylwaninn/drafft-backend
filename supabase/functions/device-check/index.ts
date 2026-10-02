// POST /device-check { token, environment, platform? } → 204
// The iPhone app sends a fresh DeviceCheck token at each launch and sign-in (never on the Simulator). Apple's
// environment is the project's (DEVICECHECK_ENVIRONMENT): the app's `environment` is only logged when it
// differs, so a client can't steer its token to the other Apple environment. The token
// is kept for db-events, which sets the device's bits when a hold changes. An account closed or on hold
// opening the app sets them again; a new account on a device where one was closed goes to review, on one
// where an account is on hold owes a selfie, once.
// The Android app (`platform: "android"`) sends a Play Integrity token each time it opens signed in: checked
// with Google before it is stored, it reads and writes Device recall, which plays the part of the two bits
// (android.ts, _shared/playintegrity.ts). Its `environment` is ignored: stored as production, there is no
// Android counterpart of DEVICECHECK_ENVIRONMENT.
// `platform` is "ios" (or missing, for the iPhone builds) or "android", else 400 invalid_platform.
// The answer never says what was found.
import { androidCheck, flagDevice, noContent } from "./android.ts";
import { deviceCheckConfigured, deviceCheckEnvironment, queryBits, updateBits } from "../_shared/devicecheck.ts";
import { HttpError, readJson, serve } from "../_shared/http.ts";
import { admin, must, requireUser } from "../_shared/supabase.ts";

serve(async (req) => {
  const user = await requireUser(req);
  const { token, environment, platform } = await readJson<
    { token?: unknown; environment?: unknown; platform?: unknown }
  >(req);
  if (platform !== undefined && platform !== "ios" && platform !== "android") {
    throw new HttpError(400, "invalid_platform");
  }
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

  if (next === "none") return noContent();
  if (!deviceCheckConfigured()) {
    console.warn(`device-check: Apple DeviceCheck not configured, ${next} skipped for ${user.id}`);
    return noContent();
  }
  try {
    if (next === "ban") {
      await updateBits(token, env, { bit0: true });
    } else if (next === "hold") {
      await updateBits(token, env, { bit1: true });
    } else {
      const bits = await queryBits(token, env);
      if (bits.bit0 || bits.bit1) {
        await flagDevice(user.id, bits, "iPhone");
      }
    }
  } catch (error) {
    // Apple down, a stale token or one from the other environment: the next launch sends a fresh one.
    // Never block the person on it, but keep Apple's answer in the logs.
    console.error(`device-check: Apple refused ${next} for ${user.id} (${env})`, error);
  }
  return noContent();
});
