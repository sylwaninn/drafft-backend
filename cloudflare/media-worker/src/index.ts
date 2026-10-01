// drafft media: serves the private R2 bucket at media.<domain>/<key>?exp=…&sig=…[&w=…].
//
// - Only a URL the backend signed and that has not expired (signature.ts). Anything else, a missing
//   object included, gets the same 404: no listing, nothing to tell a bad link from a missing object.
// - The CDN copy is keyed by object and width, never by signature, so one cached copy serves every
//   link to it. Objects never change once written (their key is a fresh UUID), so the copy can live
//   long; a deleted or hidden object stays unreachable because nobody gets a new link to it.
// - Range requests (video, audio) are answered from the cache, or from R2 while the cache fills.
// - `w` asks for a smaller photo (Cloudflare Images binding), a rendition: made once, then kept in R2 next to
//   its original (`<key>.w<width>.webp`, renditionKey) so no data centre pays the transformation again. It
//   is deleted with its original (db-events `media.deleted`, and the account's prefix on erasure), and a
//   rendition whose original is gone is never served. Without the binding, or when the transformation
//   fails, the original is served.
// - /b/<mode>/<token> serves only a blurred copy of a photo (blur_token.ts: the token hides which one,
//   the signature binds the mode). Never the original: without the binding, or when the transformation
//   fails, it is a 404.
import { blurCacheId, type BlurKeys, blurKeys, openBlurToken } from "./blur_token.ts";
import { verify } from "./signature.ts";

// Minimal shapes of the Workers runtime APIs used here (no @cloudflare/workers-types dependency, so
// Deno checks and tests this Worker like the rest of the repository).
export interface R2Range {
  offset?: number;
  length?: number;
  suffix?: number;
}
export interface R2Object {
  size: number;
  httpEtag: string;
  range?: R2Range;
  writeHttpMetadata(headers: Headers): void;
}
export interface R2ObjectBody extends R2Object {
  body: ReadableStream<Uint8Array>;
}
export interface R2Bucket {
  get(
    key: string,
    options?: { range?: Headers; onlyIf?: Headers },
  ): Promise<R2ObjectBody | R2Object | null>;
  head(key: string): Promise<R2Object | null>;
  put(
    key: string,
    value: ArrayBuffer,
    options?: { httpMetadata?: { contentType?: string } },
  ): Promise<unknown>;
  delete(key: string): Promise<void>;
}
export interface ImagesBinding {
  input(stream: ReadableStream<Uint8Array>): {
    transform(options: { width: number; fit: "scale-down"; blur?: number }): {
      output(
        options: { format: string; quality?: number },
      ): Promise<{ response(): Response }>;
    };
  };
}
export interface EdgeCache {
  match(request: Request): Promise<Response | undefined>;
  put(request: Request, response: Response): Promise<void>;
}
export interface Context {
  waitUntil(promise: Promise<unknown>): void;
}
export interface Env {
  MEDIA: R2Bucket;
  MEDIA_SIGNING_KEY: string;
  IMAGES?: ImagesBinding;
}

/** The keys media-upload-url issues: u/<user>/<folder>/<uuid>.<ext>. */
const KEY =
  /^u\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/(photos|demo|videos|posters|voice|chat)\/[A-Za-z0-9_-]{1,64}\.(jpg|heic|png|mp4|mov|m4a|aac|pdf|bin)$/;
const RESIZABLE = /\.(jpg|heic|png)$/;
/**
 * The widths the app and sophros ask for; any other value serves the original. Keep in step with
 * RENDITION_WIDTHS (supabase/functions/_shared/renditions.ts, which deletes them) and the apps' ladders.
 */
export const WIDTHS = [160, 320, 640, 1080, 1440];
const ALLOWED = new Set(WIDTHS);

/** Where a photo's rendition at `width` is kept, next to its original (same prefix, never a valid KEY). */
export const renditionKey = (key: string, width: number) => `${key}.w${width}.webp`;
/** How long the CDN keeps a copy (objects are immutable). */
const EDGE_TTL = 30 * 24 * 3600;

/**
 * Blur modes, by the name the backend signs (private.blur_url). A new rendition is a new mode name,
 * never a changed one: links already issued keep their meaning.
 */
export const BLUR_MODES: Record<string, { width: number; blur: number; quality: number }> = {
  // Likes, free account: 200 px wide, blur radius 50 (a quarter of the width), WebP. WebP output
  // carries no EXIF or other metadata.
  l1: { width: 200, blur: 50, quality: 60 },
};
const BLUR_PATH = /^\/b\/([a-z0-9]{1,8})\/([A-Za-z0-9_-]{43,256})$/;
/** Only photos have a blurred copy. */
const BLURRABLE =
  /^u\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/(photos|demo)\/[A-Za-z0-9_-]{1,64}\.(jpg|heic|png)$/;
/** How long the CDN keeps a blurred copy (per data centre; never stored in R2, see handleBlur). */
const BLUR_EDGE_TTL = 7 * 24 * 3600;

const notFound = () =>
  new Response("Not found", {
    status: 404,
    headers: { "cache-control": "no-store" },
  });

export default {
  fetch(request: Request, env: Env, ctx: Context): Promise<Response> {
    // deno-lint-ignore no-explicit-any
    const cache = (globalThis as any).caches?.default as EdgeCache | undefined;
    return handle(request, env, ctx, cache ?? null);
  },
};

export async function handle(
  request: Request,
  env: Env,
  ctx: Context,
  cache: EdgeCache | null,
): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") return notFound();
  const url = new URL(request.url);
  if (url.pathname.startsWith("/b/")) return await handleBlur(request, url, env, ctx, cache);
  const key = url.pathname.slice(1);
  if (!KEY.test(key)) return notFound();
  const exp = url.searchParams.get("exp");
  if (
    !(await verify(
      env.MEDIA_SIGNING_KEY,
      key,
      exp,
      url.searchParams.get("sig"),
    ))
  ) return notFound();

  const asked = Number(url.searchParams.get("w"));
  const width = env.IMAGES && RESIZABLE.test(key) && ALLOWED.has(asked) ? asked : null;
  // The cache key: object and width, never the signature. A GET, whatever the method asked.
  const cacheUrl = `${url.origin}/${key}${width ? `?w=${width}` : ""}`;
  const range = request.headers.get("range");
  const clientHeaders = (response: Response) => forClient(response, Number(exp), request.method);

  const hit = await cache?.match(
    new Request(cacheUrl, { headers: range ? { range } : {} }),
  );
  if (hit) return clientHeaders(hit);

  if (width) {
    const resized = await rendition(env, ctx, key, width);
    if (resized) {
      if (cache) {
        ctx.waitUntil(cache.put(new Request(cacheUrl), resized.clone()));
      }
      return clientHeaders(resized);
    }
  }

  if (range) {
    // A player's first request (bytes=0-…) fills the cache with the whole object in the background,
    // once, instead of every range doing it. This range comes from R2 now.
    if (cache && /^bytes=0-/.test(range)) {
      ctx.waitUntil(
        fullObject(env, key).then((full) => full && cache.put(new Request(cacheUrl), full)),
      );
    }
    let object: R2ObjectBody | R2Object | null;
    try {
      object = await env.MEDIA.get(key, { range: request.headers });
    } catch {
      return notFound(); // a malformed or unsatisfiable range
    }
    if (!object || !("body" in object)) return notFound();
    return clientHeaders(partial(object));
  }

  const full = await fullObject(env, key);
  if (!full) return notFound();
  if (!cache) return clientHeaders(full);
  ctx.waitUntil(cache.put(new Request(cacheUrl), full.clone()));
  return clientHeaders(full);
}

let derived: { secret: string; keys: Promise<BlurKeys> } | null = null;
function keysFor(secret: string): Promise<BlurKeys> {
  if (derived?.secret !== secret) derived = { secret, keys: blurKeys(secret) };
  return derived.keys;
}

/**
 * A blurred copy of a photo, for a blur link. Same 404 as above for anything wrong. The copy is cached
 * at the edge under an opaque id (not the token, not the media key), and is never written to R2: a
 * deleted photo or account leaves no derived file behind, and no new link to it is ever issued.
 */
async function handleBlur(
  request: Request,
  url: URL,
  env: Env,
  ctx: Context,
  cache: EdgeCache | null,
): Promise<Response> {
  const match = BLUR_PATH.exec(url.pathname);
  const mode = match && Object.hasOwn(BLUR_MODES, match[1]) ? BLUR_MODES[match[1]] : null;
  if (!match || !mode || !env.MEDIA_SIGNING_KEY) return notFound();
  const keys = await keysFor(env.MEDIA_SIGNING_KEY);
  const exp = url.searchParams.get("exp");
  const key = await openBlurToken(keys, match[1], match[2], exp, url.searchParams.get("sig"));
  if (!key || !BLURRABLE.test(key)) return notFound();

  const cacheUrl = `${url.origin}/b/${match[1]}/${await blurCacheId(keys, match[1], key)}`;
  const clientHeaders = (response: Response) => forClient(response, Number(exp), request.method);
  const hit = await cache?.match(new Request(cacheUrl));
  if (hit) return clientHeaders(hit);

  const object = await env.MEDIA.get(key);
  if (!object || !("body" in object) || !env.IMAGES) return notFound();
  let blurred: Response;
  try {
    const result = await env.IMAGES.input(object.body)
      .transform({ width: mode.width, fit: "scale-down", blur: mode.blur })
      .output({ format: "image/webp", quality: mode.quality });
    const response = result.response();
    if (!response.ok || !response.body) throw new Error(`status ${response.status}`);
    // Fresh headers: nothing of the original object (its ETag would identify the sharp file).
    const headers = new Headers({
      "content-type": "image/webp",
      "cache-control": `public, max-age=${BLUR_EDGE_TTL}`,
    });
    blurred = new Response(response.body, { status: 200, headers });
  } catch (error) {
    console.error(`blur ${match[1]}: ${error instanceof Error ? error.message : error}`);
    return notFound();
  }
  if (cache) ctx.waitUntil(cache.put(new Request(cacheUrl), blurred.clone()));
  return clientHeaders(blurred);
}

function objectHeaders(object: R2Object): Headers {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", `public, max-age=${EDGE_TTL}, immutable`);
  return headers;
}

async function fullObject(env: Env, key: string): Promise<Response | null> {
  const object = await env.MEDIA.get(key);
  if (!object || !("body" in object)) return null;
  const headers = objectHeaders(object);
  headers.set("content-length", String(object.size));
  return new Response(object.body, { status: 200, headers });
}

function partial(object: R2ObjectBody): Response {
  const headers = objectHeaders(object);
  const r = object.range ?? {};
  const start = r.suffix !== undefined ? Math.max(object.size - r.suffix, 0) : r.offset ?? 0;
  const length = r.suffix !== undefined ? object.size - start : r.length ?? object.size - start;
  headers.set(
    "content-range",
    `bytes ${start}-${start + length - 1}/${object.size}`,
  );
  headers.set("content-length", String(length));
  return new Response(object.body, { status: 206, headers });
}

/**
 * A photo at `width`: the copy kept in R2, or made now (then kept, in the background). A kept copy whose
 * original is gone is deleted instead of served (a deletion that raced with its making).
 */
async function rendition(
  env: Env,
  ctx: Context,
  key: string,
  width: number,
): Promise<Response | null> {
  const stored = renditionKey(key, width);
  const [kept, original] = await Promise.all([env.MEDIA.get(stored), env.MEDIA.head(key)]);
  if (!original) {
    if (kept) ctx.waitUntil(env.MEDIA.delete(stored));
    return null;
  }
  if (kept && "body" in kept) {
    const headers = objectHeaders(kept);
    headers.set("content-length", String(kept.size));
    headers.delete("accept-ranges");
    return new Response(kept.body, { status: 200, headers });
  }
  const made = await resize(env, key, width);
  if (!made) return null;
  let body: ArrayBuffer;
  try {
    body = await made.arrayBuffer();
  } catch (error) {
    console.error(`resize ${key} w${width}: ${error instanceof Error ? error.message : error}`);
    return null;
  }
  if (body.byteLength === 0) return null;
  ctx.waitUntil(keep(env, key, stored, body));
  return new Response(body, { status: 200, headers: made.headers });
}

/**
 * Writes a rendition, then looks at its original again: deleted meanwhile (media.deleted deletes the
 * original first, then its renditions), the copy goes too, so none outlives its photo.
 */
async function keep(env: Env, key: string, stored: string, body: ArrayBuffer): Promise<void> {
  try {
    await env.MEDIA.put(stored, body, { httpMetadata: { contentType: "image/webp" } });
    if (!(await env.MEDIA.head(key))) await env.MEDIA.delete(stored);
  } catch (error) {
    console.error(`keep ${stored}: ${error instanceof Error ? error.message : error}`);
  }
}

async function resize(
  env: Env,
  key: string,
  width: number,
): Promise<Response | null> {
  const object = await env.MEDIA.get(key);
  if (!object || !("body" in object) || !env.IMAGES) return null;
  try {
    const result = await env.IMAGES.input(object.body).transform({
      width,
      fit: "scale-down",
    })
      .output({ format: "image/webp", quality: 85 });
    const response = result.response();
    // Never a failed or empty transformation: it would be kept in R2 for good.
    if (!response.ok || !response.body) throw new Error(`status ${response.status}`);
    const headers = new Headers(response.headers);
    headers.set("etag", `${object.httpEtag.replace(/"$/, "")}-w${width}"`);
    headers.set("cache-control", `public, max-age=${EDGE_TTL}, immutable`);
    return new Response(response.body, { status: 200, headers });
  } catch (error) {
    console.error(
      `resize ${key} w${width}: ${error instanceof Error ? error.message : error}`,
    );
    return null;
  }
}

/**
 * What the app or browser sees: kept privately until the link expires (at most an hour), never
 * stored by a shared cache under the signed URL.
 */
function forClient(response: Response, exp: number, method: string): Response {
  const headers = new Headers(response.headers);
  const left = Math.max(0, Math.min(3600, Math.floor(exp - Date.now() / 1000)));
  headers.set("cache-control", `private, max-age=${left}`);
  headers.set("x-content-type-options", "nosniff");
  headers.set("cross-origin-resource-policy", "cross-origin");
  headers.delete("cf-cache-status");
  if (headers.get("content-type") === "application/octet-stream") {
    headers.set("content-disposition", "attachment");
  }
  return new Response(method === "HEAD" ? null : response.body, {
    status: response.status,
    headers,
  });
}
