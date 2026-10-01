// Firebase Cloud Messaging, HTTP v1 API: the Android phones (`_shared/push.ts` picks them). Chat
// messages are pushed by Stream itself (its `drafft-fcm` push provider).
//
// FCM_SERVICE_ACCOUNT is the Firebase project's service account key (JSON, on one line), from the
// project the Android app's google-services.json belongs to: one per environment.
import { importPKCS8, SignJWT } from "npm:jose@6";
import { env, optionalEnv } from "./env.ts";
import { admin } from "./supabase.ts";
import { transientStatus } from "./providers.ts";
import type { Device, Outcome, Push } from "./push.ts";

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

let account: ServiceAccount | undefined;
let cached: { token: string; until: number } | undefined;

function serviceAccount(): ServiceAccount {
  account ??= JSON.parse(env("FCM_SERVICE_ACCOUNT")) as ServiceAccount;
  return account;
}

export function fcmConfigured(): boolean {
  return !!optionalEnv("FCM_SERVICE_ACCOUNT");
}

// Google's OAuth access tokens last an hour: one is reused until 5 minutes before it ends.
async function accessToken(): Promise<string> {
  if (cached && Date.now() < cached.until) return cached.token;
  const sa = serviceAccount();
  const key = await importPKCS8(sa.private_key.replace(/\\n/g, "\n"), "RS256");
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/firebase.messaging" })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(key);
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    signal: AbortSignal.timeout(10_000),
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!res.ok) throw Object.assign(new Error(`FCM OAuth ${res.status}`), { status: res.status });
  const { access_token, expires_in } = await res.json() as { access_token: string; expires_in: number };
  cached = { token: access_token, until: Date.now() + (expires_in - 300) * 1000 };
  return access_token;
}

/**
 * The Android notification channel (the app creates them, `LocalNotifications.Channel`), chosen like the
 * app's own `NotificationService.channel`: the same pushes land in the same place, app open or not.
 */
export function androidChannel(data: Record<string, string> = {}): string {
  const kind = data.kind ?? "";
  if (kind === "match") return "matches";
  if (kind === "like" || kind === "super_like") return "likes";
  if (kind === "photo_refused" || kind === "moderation" || kind === "weekly_boost") return "account";
  if (kind.startsWith("session")) return "sessions";
  return "messages";
}

/** Sends to each device on its own. Tokens FCM reports as dead are removed. */
export async function sendFcm(userId: string, devices: Device[], push: Push): Promise<Outcome[]> {
  let bearer: string;
  try {
    bearer = await accessToken();
  } catch (error) {
    console.error(`FCM sign-in failed for user ${userId}: ${error}`);
    const status = (error as { status?: number }).status;
    const outcome: Outcome = status === undefined || transientStatus(status) ? "down" : "refused";
    return devices.map(() => outcome);
  }
  const url = `https://fcm.googleapis.com/v1/projects/${serviceAccount().project_id}/messages:send`;

  return await Promise.all(
    devices.map(async ({ token }): Promise<Outcome> => {
      const message = {
        token,
        notification: { title: push.title, body: push.body },
        data: push.data ?? {},
        android: {
          priority: "HIGH",
          ...(push.collapseId ? { collapse_key: push.collapseId } : {}),
          notification: {
            channel_id: androidChannel(push.data),
            sound: "default",
            // Same tag, same notification: replaced instead of stacked (APNs' collapse id).
            ...(push.collapseId ? { tag: push.collapseId } : {}),
          },
        },
      };
      let res: Response;
      try {
        res = await fetch(url, {
          method: "POST",
          signal: AbortSignal.timeout(10_000),
          headers: { authorization: `Bearer ${bearer}`, "content-type": "application/json" },
          body: JSON.stringify({ message }),
        });
      } catch (error) {
        console.error(`FCM unreachable for user ${userId}: ${error}`);
        return "down";
      }
      if (res.ok) return "sent";
      if (res.status === 401) cached = undefined;
      const error = (await res.json().catch(() => ({})) as {
        error?: { status?: string; message?: string; details?: { errorCode?: string }[] };
      }).error;
      const code = error?.details?.find((d) => d.errorCode)?.errorCode ?? error?.status ?? "";
      // UNREGISTERED: the app was uninstalled or the token rotated; SENDER_ID_MISMATCH: a token of another
      // Firebase project (another environment's build); INVALID_ARGUMENT only when it's about the token,
      // never for a message FCM didn't like (that would erase good tokens).
      const badToken = code === "INVALID_ARGUMENT" && /registration token/i.test(error?.message ?? "");
      if (res.status === 404 || code === "UNREGISTERED" || code === "SENDER_ID_MISMATCH" || badToken) {
        await admin.from("push_tokens").delete().eq("token", token);
        return "refused";
      }
      console.error(`FCM ${res.status} ${code} for user ${userId}`);
      return transientStatus(res.status) ? "down" : "refused";
    }),
  );
}
