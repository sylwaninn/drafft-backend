// Signed media URLs, the format the media Worker (cloudflare/media-worker) checks:
//   <MEDIA_PUBLIC_URL>/<key>?exp=<unix seconds>&sig=<base64url(HMAC-SHA256(MEDIA_SIGNING_KEY, key + "\n" + exp))>
// The database signs the same way (private.sign_media_key, 20260928000141) and so does sophros. Keep
// the four in step: the shared test vector is in media_url_test.ts, the Worker's and the pgTAP test.
import { env, optionalEnv } from "./env.ts";
import { assertSafeKey } from "./r2.ts";

const encoder = new TextEncoder();

/** At least an hour ahead, rounded up to the quarter hour, like the database. */
export function mediaExpiry(now = Date.now()): number {
  return Math.ceil((now / 1000 + 3600) / 900) * 900;
}

export async function mediaSignature(secret: string, key: string, exp: number): Promise<string> {
  const hmac = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", hmac, encoder.encode(`${key}\n${exp}`)));
  return btoa(String.fromCharCode(...mac)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * A URL to one object, signed when MEDIA_SIGNING_KEY is set (unsigned otherwise: the public bucket
 * still serves it while the switch is under way). Only for media the caller may see.
 */
export async function signedMediaUrl(key: string, now = Date.now()): Promise<string> {
  const base = `${env("MEDIA_PUBLIC_URL").replace(/\/+$/, "")}/${assertSafeKey(key)}`;
  const secret = optionalEnv("MEDIA_SIGNING_KEY");
  if (!secret) return base;
  const exp = mediaExpiry(now);
  return `${base}?exp=${exp}&sig=${await mediaSignature(secret, key, exp)}`;
}
