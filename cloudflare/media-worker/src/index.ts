// drafft media: serves the private R2 bucket at media.<domain>/<key>?exp=…&sig=…[&w=…].
//
// - Only a URL the backend signed and that has not expired (signature.ts). Anything else, a missing
//   object included, gets the same 404: no listing, nothing to tell a bad link from a missing object.
// - The CDN copy is keyed by object and width, never by signature, so one cached copy serves every
//   link to it. Objects never change once written (their key is a fresh UUID), so the copy can live
//   long; a deleted or hidden object stays unreachable because nobody gets a new link to it.
// - Range requests (video, audio) are answered from the cache, or from R2 while the cache fills.
// - `w` asks for a smaller photo (Cloudflare Images binding). Without the binding, or when the
//   transformation fails, the original is served.
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
}
export interface ImagesBinding {
  input(stream: ReadableStream<Uint8Array>): {
    transform(options: { width: number; fit: "scale-down" }): {
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
/** The widths the app and sophros ask for; any other value serves the original. */
const WIDTHS = new Set([160, 320, 640, 1080]);
/** How long the CDN keeps a copy (objects are immutable). */
const EDGE_TTL = 30 * 24 * 3600;

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
  const width = env.IMAGES && RESIZABLE.test(key) && WIDTHS.has(asked) ? asked : null;
  // The cache key: object and width, never the signature. A GET, whatever the method asked.
  const cacheUrl = `${url.origin}/${key}${width ? `?w=${width}` : ""}`;
  const range = request.headers.get("range");
  const clientHeaders = (response: Response) => forClient(response, Number(exp), request.method);

  const hit = await cache?.match(
    new Request(cacheUrl, { headers: range ? { range } : {} }),
  );
  if (hit) return clientHeaders(hit);

  if (width) {
    const resized = await resize(env, key, width);
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
