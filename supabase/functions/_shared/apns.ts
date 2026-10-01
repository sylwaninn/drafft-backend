// Apple Push Notification service, token-based (.p8 key): the iPhone's devices (`_shared/push.ts` picks
// them). Chat messages are pushed by Stream itself, once the same key is configured in its dashboard.
import { importPKCS8, SignJWT } from "npm:jose@6";
import { env, optionalEnv } from "./env.ts";
import { admin } from "./supabase.ts";
import { transientStatus } from "./providers.ts";
import type { Device, Outcome, Push } from "./push.ts";

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

export function apnsConfigured(): boolean {
  return !!optionalEnv("APNS_KEY_ID");
}

/** Sends to each device on its own. Tokens Apple reports as dead are removed. */
export async function sendApns(userId: string, devices: Device[], push: Push): Promise<Outcome[]> {
  const jwt = await providerToken();
  const payload = JSON.stringify({
    aps: { alert: { title: push.title, body: push.body }, sound: "default" },
    ...push.data,
  });

  return await Promise.all(
    devices.map(async ({ token, environment }): Promise<Outcome> => {
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
}
