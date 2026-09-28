// Apple Push Notification service, token-based (.p8 key). Used for everything except chat messages,
// which Stream pushes itself once the same key is configured in the Stream dashboard.
import { importPKCS8, SignJWT } from "npm:jose@6";
import { env, optionalEnv } from "./env.ts";
import { admin, must } from "./supabase.ts";
import { ProviderError, reachedProvider, transientStatus } from "./providers.ts";

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

/**
 * Sends to every device of a person. Tokens Apple reports as dead are removed. Each device is tried on its
 * own: one that fails doesn't stop the others. When APNs is down for every device (5xx, 429, network), a
 * transient ProviderError asks for a retry; when some got it, the others are logged, not retried, so a retry
 * never pushes twice to a device already served (and a late push is worse than none).
 */
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

  const outcomes = await Promise.all(
    tokens.map(async ({ token, environment }): Promise<"sent" | "down" | "refused"> => {
      const host = environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
      let res: Response;
      try {
        res = await fetch(`https://${host}/3/device/${token}`, {
          method: "POST",
          signal: AbortSignal.timeout(10_000),
          headers: {
            authorization: `bearer ${jwt}`,
            "apns-topic": env("APNS_BUNDLE_ID"),
            "apns-push-type": "alert",
            "apns-priority": "10",
            ...(push.collapseId ? { "apns-collapse-id": push.collapseId } : {}),
          },
          body: payload,
        });
      } catch (error) {
        console.error(`APNs unreachable for user ${userId}: ${error}`);
        return "down";
      }
      if (res.ok) return "sent";
      const reason = (await res.json().catch(() => ({})) as { reason?: string }).reason;
      if (res.status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
        await admin.from("push_tokens").delete().eq("token", token);
        return "refused";
      }
      console.error(`APNs ${res.status} ${reason ?? ""} for user ${userId}`);
      return transientStatus(res.status) ? "down" : "refused";
    }),
  );

  if (outcomes.includes("sent") || outcomes.includes("refused")) reachedProvider("apns");
  if (outcomes.every((o) => o === "down")) {
    throw new ProviderError("apns", true, `APNs down for every device of user ${userId}`);
  }
}
