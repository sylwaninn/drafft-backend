// Pushes to a person's devices: iPhones through APNs (`apns.ts`), Android phones through FCM (`fcm.ts`),
// from `push_tokens.platform`. Chat messages don't come through here: Stream pushes them.
import { admin, must } from "./supabase.ts";
import { type Provider, ProviderError, reachedProvider } from "./providers.ts";
import { apnsConfigured, sendApns } from "./apns.ts";
import { fcmConfigured, sendFcm } from "./fcm.ts";

export interface Push {
  title: string;
  body: string;
  /** Opens this place in the app, e.g. { "match": "<id>" }; `kind` also picks the Android channel. */
  data?: Record<string, string>;
  /** Replaces an earlier notification with the same id instead of stacking. */
  collapseId?: string;
}

export interface Device {
  token: string;
  environment: string;
}

/** What one device's send came to: delivered, refused for good (dead token, bad request), or the
 * service was unreachable or down. */
export type Outcome = "sent" | "refused" | "down";

const services: {
  provider: Provider;
  platform: "ios" | "android";
  configured: () => boolean;
  send: (userId: string, devices: Device[], push: Push) => Promise<Outcome[]>;
}[] = [
  { provider: "apns", platform: "ios", configured: apnsConfigured, send: sendApns },
  { provider: "fcm", platform: "android", configured: fcmConfigured, send: sendFcm },
];

/**
 * Sends to every device of a person. Each device is tried on its own: one that fails doesn't stop the
 * others. When the service is down for every device (5xx, 429, network), a transient ProviderError naming
 * it asks for a retry; when some got it, the others are logged, not retried, so a retry never pushes twice
 * to a device already served (and a late push is worse than none). A service that isn't configured
 * (locally) is skipped with a warning.
 */
export async function pushToUser(userId: string, push: Push): Promise<void> {
  const tokens = must(
    await admin.from("push_tokens").select("token, environment, platform").eq("user_id", userId),
    "push tokens",
  ) as (Device & { platform?: string })[];
  if (tokens.length === 0) return;

  const results = await Promise.all(services.map(async (service) => {
    const devices = tokens.filter((t) => (t.platform ?? "ios") === service.platform);
    if (devices.length === 0) return { service, outcomes: [] as Outcome[] };
    if (!service.configured()) {
      console.warn(`${service.provider} not configured, skipped push to ${userId}: ${push.title}`);
      return { service, outcomes: [] as Outcome[] };
    }
    return { service, outcomes: await service.send(userId, devices, push) };
  }));

  for (const { service, outcomes } of results) {
    if (outcomes.some((o) => o !== "down")) reachedProvider(service.provider);
  }
  const all = results.flatMap((r) => r.outcomes);
  if (all.length > 0 && all.every((o) => o === "down")) {
    const down = results.find((r) => r.outcomes.length > 0)!.service.provider;
    throw new ProviderError(down, true, `${down} down for every device of user ${userId}`);
  }
}
