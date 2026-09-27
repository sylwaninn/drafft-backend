// POST /device-check { token, environment } → 204
// The app sends a fresh DeviceCheck token at each launch and sign-in (never on the Simulator). The token
// is kept for db-events, which sets the iPhone's bits when a hold changes. An account closed or on hold
// opening the app sets them again; a new account on an iPhone where one was closed goes to review, on one
// where an account is on hold owes a selfie, once.
// The answer never says what was found.
import { deviceCheckConfigured, type DeviceEnvironment, queryBits, updateBits } from "../_shared/devicecheck.ts";
import { HttpError, readJson, serve } from "../_shared/http.ts";
import { admin, check, must, requireUser } from "../_shared/supabase.ts";

serve(async (req) => {
  const user = await requireUser(req);
  const { token, environment } = await readJson<{ token?: unknown; environment?: unknown }>(req);
  if (typeof token !== "string" || token.length < 20 || token.length > 8192) {
    throw new HttpError(400, "invalid_token");
  }
  const env: DeviceEnvironment = environment === "development" ? "development" : "production";
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
    // Apple down or a stale token: the next launch sends a fresh one. Never block the person on it.
    console.error("device-check", error);
  }
  return new Response(null, { status: 204 });
});
