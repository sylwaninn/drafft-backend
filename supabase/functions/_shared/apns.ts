// Apple Push Notification service, token-based (.p8 key). Used for everything except chat messages,
// which Stream pushes itself once the same key is configured in the Stream dashboard.
import { importPKCS8, SignJWT } from "npm:jose@6";
import { env, optionalEnv } from "./env.ts";
import { admin, must } from "./supabase.ts";

let cached: { jwt: string; at: number } | undefined;

// Apple accepts a provider token for up to an hour and rejects refreshing it more than every 20 min.
async function providerToken(): Promise<string> {
  if (cached && Date.now() - cached.at < 45 * 60 * 1000) return cached.jwt;
  const key = await importPKCS8(env("APNS_PRIVATE_KEY").replace(/\\n/g, "\n"), "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env("APNS_KEY_ID") })
    .setIssuer(env("APNS_TEAM_ID"))
    .setIssuedAt()
    .sign(key);
  cached = { jwt, at: Date.now() };
  return jwt;
}

export interface Push {
  title: string;
  body: string;
  /** Opens this place in the app, e.g. { "match": "<id>" }. */
  data?: Record<string, string>;
  /** Replaces an earlier notification with the same id instead of stacking. */
  collapseId?: string;
}

/** Sends to every device of a person. Tokens Apple reports as dead are removed. */
export async function pushToUser(userId: string, push: Push): Promise<void> {
  if (!optionalEnv("APNS_KEY_ID")) {
    console.warn(`APNs not configured, skipped push to ${userId}: ${push.title}`);
    return;
  }
  const tokens = must(
    await admin.from("push_tokens").select("token, environment").eq("user_id", userId),
    "push tokens",
  );
  if (tokens.length === 0) return;
  const jwt = await providerToken();
  const payload = JSON.stringify({
    aps: { alert: { title: push.title, body: push.body }, sound: "default" },
    ...push.data,
  });

  await Promise.all(tokens.map(async ({ token, environment }) => {
    const host = environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    const res = await fetch(`https://${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": env("APNS_BUNDLE_ID"),
        "apns-push-type": "alert",
        "apns-priority": "10",
        ...(push.collapseId ? { "apns-collapse-id": push.collapseId } : {}),
      },
      body: payload,
    });
    if (res.ok) return;
    const reason = (await res.json().catch(() => ({})) as { reason?: string }).reason;
    if (res.status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
      await admin.from("push_tokens").delete().eq("token", token);
      return;
    }
    // A failed push is logged, not retried: a late "it's a match" is worse than none.
    console.error(`APNs ${res.status} ${reason ?? ""} for user ${userId}`);
  }));
}
