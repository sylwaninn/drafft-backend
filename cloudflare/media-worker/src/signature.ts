// The media URL signature, shared with the backend (supabase/functions/_shared/media_url.ts,
// private.sign_media_key) and sophros:
//   sig = base64url(HMAC-SHA256(MEDIA_SIGNING_KEY, key + "\n" + exp)), without padding
// `exp` is a Unix time in seconds. The size variant (`w`) is not signed: it only picks among a few
// widths the Worker allows.

const encoder = new TextEncoder();

/** Links are issued for about an hour; anything further ahead was not issued by the backend. */
export const MAX_LIFETIME_SECONDS = 2 * 3600;

async function hmacKey(
  secret: string,
  usage: "sign" | "verify",
): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    [
      usage,
    ],
  );
}

function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(
    /\//g,
    "_",
  ).replace(/=+$/, "");
}

function fromBase64Url(text: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]{43}$/.test(text)) return null; // 32 bytes, unpadded
  const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=");
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

export async function sign(
  secret: string,
  key: string,
  exp: number,
): Promise<string> {
  const mac = await crypto.subtle.sign(
    "HMAC",
    await hmacKey(secret, "sign"),
    encoder.encode(`${key}\n${exp}`),
  );
  return toBase64Url(new Uint8Array(mac));
}

/**
 * Whether `sig` signs `key` until `exp`, and `exp` is still ahead of `now` (ms), within the lifetime
 * the backend issues. Constant time (crypto.subtle.verify).
 */
export async function verify(
  secret: string,
  key: string,
  exp: string | null,
  sig: string | null,
  now = Date.now(),
): Promise<boolean> {
  if (!secret || !exp || !sig || !/^\d{1,12}$/.test(exp)) return false;
  const expires = Number(exp);
  const nowSeconds = now / 1000;
  if (expires <= nowSeconds || expires > nowSeconds + MAX_LIFETIME_SECONDS) {
    return false;
  }
  const mac = fromBase64Url(sig);
  if (!mac) return false;
  return await crypto.subtle.verify(
    "HMAC",
    await hmacKey(secret, "verify"),
    mac,
    encoder.encode(`${key}\n${expires}`),
  );
}
