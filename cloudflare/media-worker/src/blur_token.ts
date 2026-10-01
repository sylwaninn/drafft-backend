// Blurred photo links (Likes for a free account, 20261001000301_blurred_like_photos.sql), shared with
// private.blur_url in the database:
//
//   <base>/b/<mode>/<token>?exp=<unix seconds>&sig=<signature>
//
// The token hides which photo it is: encrypt-then-MAC (AES-256-CBC, then HMAC-SHA256), the
// construction of JWE's A256CBC-HS512, with keys derived from MEDIA_SIGNING_KEY:
//   enc: HMAC-SHA256 of MEDIA_SIGNING_KEY labelled drafft-blur-enc-v1
//   iv: HMAC-SHA256 (under the MEDIA_SIGNING_KEY label drafft-blur-iv-v1) of viewer + "\n" + key + "\n" + exp)[0..16]
//   mac: HMAC-SHA256 of MEDIA_SIGNING_KEY labelled drafft-blur-mac-v1
//   token = base64url(iv || AES-256-CBC-PKCS7(enc, iv, key))
//   sig   = base64url(HMAC-SHA256(mac, mode + "\n" + token + "\n" + exp))
// base64url without padding. The media key (u/<user id>/...) never appears in clear; the signature binds
// the mode and the expiry, and its key differs from the one of ordinary links (signature.ts), so a blur
// link cannot be turned into a sharp one or a sharper mode. The iv depends on the viewer and the
// expiry: two people never get the same token for one photo, and a token changes every quarter hour.
import { MAX_LIFETIME_SECONDS } from "./signature.ts";

const encoder = new TextEncoder();

export interface BlurKeys {
  enc: CryptoKey;
  mac: CryptoKey;
  iv: CryptoKey;
  /** For the cache key of a photo's blurred copy: never the media key itself. */
  cacheId: CryptoKey;
}

async function hmac(key: BufferSource, data: string): Promise<Uint8Array<ArrayBuffer>> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, encoder.encode(data)));
}

const hmacKey = (raw: BufferSource, usage: KeyUsage[]) =>
  crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, usage);

export async function blurKeys(secret: string): Promise<BlurKeys> {
  const s = encoder.encode(secret);
  return {
    enc: await crypto.subtle.importKey("raw", await hmac(s, "drafft-blur-enc-v1"), "AES-CBC", false, [
      "encrypt",
      "decrypt",
    ]),
    mac: await hmacKey(await hmac(s, "drafft-blur-mac-v1"), ["sign", "verify"]),
    iv: await hmacKey(await hmac(s, "drafft-blur-iv-v1"), ["sign"]),
    cacheId: await hmacKey(await hmac(s, "drafft-blur-cache-v1"), ["sign"]),
  };
}

export function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64Url(text: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]+$/.test(text) || text.length % 4 === 1) return null;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  try {
    return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

/** The token and signature for `key` (what private.blur_url computes; the Worker only opens). */
export async function sealBlurToken(
  secret: string,
  key: string,
  mode: string,
  viewer: string,
  exp: number,
): Promise<{ token: string; sig: string }> {
  const keys = await blurKeys(secret);
  const iv = new Uint8Array(
    await crypto.subtle.sign("HMAC", keys.iv, encoder.encode(`${viewer}\n${key}\n${exp}`)),
  ).slice(0, 16);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-CBC", iv }, keys.enc, encoder.encode(key)));
  const token = toBase64Url(new Uint8Array([...iv, ...ct]));
  const sig = toBase64Url(
    new Uint8Array(await crypto.subtle.sign("HMAC", keys.mac, encoder.encode(`${mode}\n${token}\n${exp}`))),
  );
  return { token, sig };
}

/**
 * The media key a blur link stands for, when `sig` signs this mode, token and expiry, and the link has
 * not expired (within the lifetime the backend issues); null otherwise. The signature is checked (in
 * constant time) before anything is decrypted, so a forged token never reaches AES.
 */
export async function openBlurToken(
  keys: BlurKeys,
  mode: string,
  token: string,
  exp: string | null,
  sig: string | null,
  now = Date.now(),
): Promise<string | null> {
  if (!exp || !sig || !/^\d{1,12}$/.test(exp)) return null;
  const expires = Number(exp);
  const nowSeconds = now / 1000;
  if (expires <= nowSeconds || expires > nowSeconds + MAX_LIFETIME_SECONDS) return null;
  const mac = /^[A-Za-z0-9_-]{43}$/.test(sig) ? fromBase64Url(sig) : null;
  if (!mac) return null;
  const valid = await crypto.subtle.verify("HMAC", keys.mac, mac, encoder.encode(`${mode}\n${token}\n${expires}`));
  if (!valid) return null;
  const bytes = fromBase64Url(token);
  // An iv and at least one block, whole blocks only.
  if (!bytes || bytes.length < 32 || bytes.length % 16 !== 0) return null;
  try {
    const plain = await crypto.subtle.decrypt({ name: "AES-CBC", iv: bytes.slice(0, 16) }, keys.enc, bytes.slice(16));
    return new TextDecoder("utf-8", { fatal: true }).decode(plain);
  } catch {
    return null;
  }
}

/** A stable, opaque id for the blurred copy of `key` in `mode` (the CDN cache key). */
export async function blurCacheId(keys: BlurKeys, mode: string, key: string): Promise<string> {
  const id = await crypto.subtle.sign("HMAC", keys.cacheId, encoder.encode(`${mode}\n${key}`));
  return toBase64Url(new Uint8Array(id));
}
