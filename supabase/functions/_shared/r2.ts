// Cloudflare R2 through its S3-compatible API. Objects are public through the CDN domain
// (MEDIA_PUBLIC_URL) under unguessable keys; writes need a presigned URL from media-upload-url.
import { AwsClient } from "npm:aws4fetch@1";
import { env, optionalEnv } from "./env.ts";
import { ProviderError, reachedProvider, transientStatus, viaProvider } from "./providers.ts";

let aws: AwsClient | undefined;

/** Created on first use, like the Stream client. */
function client(): AwsClient {
  aws ??= new AwsClient({
    accessKeyId: env("R2_ACCESS_KEY_ID"),
    secretAccessKey: env("R2_SECRET_ACCESS_KEY"),
    service: "s3",
    region: optionalEnv("R2_REGION") ?? "auto",
  });
  return aws;
}

// R2_ENDPOINT (and R2_REGION) override Cloudflare, e.g. the local Supabase Storage S3 API in development.
function bucketUrl(): string {
  const base = optionalEnv("R2_ENDPOINT") ?? `https://${env("R2_ACCOUNT_ID")}.r2.cloudflarestorage.com`;
  return `${base}/${env("R2_BUCKET")}`;
}

/**
 * Refuses a key that could point outside its own path once turned into a URL: URL parsing resolves
 * `.` and `..` segments, so a key under the caller's prefix could still reach another object. Keys come
 * from media-upload-url (`u/<user>/<folder>/<uuid>.<ext>`) and the database checks their shape too;
 * this is the last guard before a request reaches the bucket.
 */
export function assertSafeKey(key: string): string {
  if (typeof key !== "string" || key.length === 0 || key.length > 512) throw new Error("R2: invalid object key");
  for (const segment of key.split("/")) {
    // `%2e` counts as a dot for URL parsers too.
    if (segment === "" || /^(\.|%2e){1,2}$/i.test(segment)) throw new Error("R2: invalid object key");
  }
  return key;
}

function objectUrl(key: string): URL {
  return new URL(`${bucketUrl()}/${assertSafeKey(key).split("/").map(encodeURIComponent).join("/")}`);
}

export function publicUrl(key: string): string {
  return `${env("MEDIA_PUBLIC_URL")}/${assertSafeKey(key)}`;
}

/**
 * PUT URL valid for `expiresIn` seconds. Content type and length are signed: the upload must send
 * exactly these headers, so the size limit checked here holds.
 */
export async function presignPut(key: string, contentType: string, byteSize: number, expiresIn = 600): Promise<string> {
  const url = objectUrl(key);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));
  const signed = await client().sign(
    new Request(url, {
      method: "PUT",
      headers: { "content-type": contentType, "content-length": String(byteSize) },
    }),
    { aws: { signQuery: true, allHeaders: true } },
  );
  return signed.url;
}

/** A request to the bucket. A network failure is the "r2" provider's; any answer means it's up. */
async function r2(url: URL, init?: RequestInit): Promise<Response> {
  const res = await viaProvider("r2", () => client().fetch(url, init));
  if (transientStatus(res.status)) throw r2Error(init?.method ?? "GET", url.pathname, res.status);
  reachedProvider("r2");
  return res;
}

function r2Error(method: string, key: string, status: number): ProviderError {
  return new ProviderError("r2", transientStatus(status), `R2 ${method} ${key}: ${status}`, status);
}

/** Size in bytes, or null when the object doesn't exist. */
export async function headObject(key: string): Promise<number | null> {
  const res = await r2(objectUrl(key), { method: "HEAD" });
  if (res.status === 404) return null;
  if (!res.ok) throw r2Error("HEAD", key, res.status);
  return Number(res.headers.get("content-length") ?? 0);
}

/** The object's bytes, or null when it doesn't exist. */
export async function getObject(key: string): Promise<Uint8Array | null> {
  const res = await r2(objectUrl(key));
  if (res.status === 404) return null;
  if (!res.ok) throw r2Error("GET", key, res.status);
  return new Uint8Array(await res.arrayBuffer());
}

export async function deleteObject(key: string): Promise<void> {
  const res = await r2(objectUrl(key), { method: "DELETE" });
  // 204 when deleted, 404 when already gone: both mean done.
  if (!res.ok && res.status !== 404) throw r2Error("DELETE", key, res.status);
}

/** Every key under a prefix (paginated ListObjectsV2). */
export async function listKeys(prefix: string): Promise<string[]> {
  const keys: string[] = [];
  let token: string | undefined;
  do {
    const url = new URL(bucketUrl());
    url.searchParams.set("list-type", "2");
    url.searchParams.set("prefix", prefix);
    if (token) url.searchParams.set("continuation-token", token);
    const res = await client().fetch(url);
    if (!res.ok) throw new Error(`R2 LIST ${prefix}: ${res.status}`);
    const xml = await res.text();
    for (const m of xml.matchAll(/<Key>([^<]+)<\/Key>/g)) keys.push(decodeXml(m[1]));
    token = xml.match(/<NextContinuationToken>([^<]+)<\/NextContinuationToken>/)?.[1];
  } while (token);
  return keys;
}

function decodeXml(s: string): string {
  return s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}
