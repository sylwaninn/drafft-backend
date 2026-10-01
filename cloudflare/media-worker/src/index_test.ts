import { assertEquals } from "jsr:@std/assert@1";
import {
  type Context,
  type EdgeCache,
  type Env,
  handle,
  type ImagesBinding,
  type R2Bucket,
  type R2ObjectBody,
  RENDITION_QUALITY,
  renditionKey,
  WIDTHS,
} from "./index.ts";
import * as deletion from "../../../supabase/functions/_shared/renditions.ts";
import { sealBlurToken } from "./blur_token.ts";
import { sign } from "./signature.ts";

const secret = "test-signing-key";
const key = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/videos/clip.mp4";
const bytes = new TextEncoder().encode("0123456789");

function bucket(
  objects: Record<string, Uint8Array>,
): R2Bucket & { gets: number; puts: string[]; deletes: string[] } {
  const b = {
    gets: 0,
    puts: [] as string[],
    deletes: [] as string[],
    head(k: string) {
      const data = objects[k];
      return Promise.resolve(
        data ? { size: data.length, httpEtag: '"e1"', writeHttpMetadata: () => {} } : null,
      );
    },
    put(k: string, value: ArrayBuffer) {
      b.puts.push(k);
      objects[k] = new Uint8Array(value);
      return Promise.resolve(null);
    },
    delete(k: string) {
      b.deletes.push(k);
      delete objects[k];
      return Promise.resolve();
    },
    get(
      k: string,
      options?: { range?: Headers },
    ): Promise<R2ObjectBody | null> {
      b.gets++;
      const data = objects[k];
      if (!data) return Promise.resolve(null);
      const m = options?.range?.get("range")?.match(/^bytes=(\d+)-(\d*)$/);
      const offset = m ? Number(m[1]) : 0;
      const end = m && m[2] ? Number(m[2]) + 1 : data.length;
      return Promise.resolve({
        size: data.length,
        httpEtag: '"e1"',
        range: m ? { offset, length: end - offset } : undefined,
        writeHttpMetadata: (h: Headers) => h.set("content-type", "video/mp4"),
        body: new Response(data.slice(offset, end)).body!,
      });
    },
  };
  return b;
}

function memoryCache(): EdgeCache & { keys: string[] } {
  const store = new Map<string, Response>();
  return {
    get keys() {
      return [...store.keys()];
    },
    match: (r) => Promise.resolve(store.get(r.url)?.clone()),
    put: async (r, res) => void store.set(r.url, new Response(await res.arrayBuffer(), res)),
  };
}

function context(): Context & { done: () => Promise<unknown> } {
  const pending: Promise<unknown>[] = [];
  return {
    waitUntil: (p) => void pending.push(p),
    done: () => Promise.all(pending),
  };
}

async function link(k = key, ttl = 3600): Promise<string> {
  const exp = Math.floor(Date.now() / 1000) + ttl;
  return `https://media.test/${k}?exp=${exp}&sig=${await sign(secret, k, exp)}`;
}

const env = (b: R2Bucket): Env => ({ MEDIA: b, MEDIA_SIGNING_KEY: secret });

Deno.test("a signed link serves the object, then the CDN copy", async () => {
  const b = bucket({ [key]: bytes });
  const cache = memoryCache();
  const ctx = context();
  const res = await handle(new Request(await link()), env(b), ctx, cache);
  assertEquals(res.status, 200);
  assertEquals(await res.text(), "0123456789");
  assertEquals(
    res.headers.get("cache-control")?.startsWith("private, max-age="),
    true,
  );
  await ctx.done();
  assertEquals(
    cache.keys,
    [`https://media.test/${key}`],
    "cached by key, without the signature",
  );

  const again = await handle(
    new Request(await link(key, 1800)),
    env(b),
    context(),
    cache,
  );
  assertEquals(await again.text(), "0123456789");
  assertEquals(
    b.gets,
    1,
    "the second link, signed differently, reads the CDN copy",
  );
});

Deno.test("the same 404 for a bad signature, an expired link, a bad key and a missing object", async () => {
  const b = bucket({ [key]: bytes });
  const good = new URL(await link());
  const tampered = new URL(good);
  tampered.searchParams.set("sig", "A".repeat(43));
  const expired = await link(key, -10);
  const missing = await link(key.replace("clip", "gone"));
  const traversal = good.href.replace("/videos/", "/videos/../photos/");
  for (
    const url of [
      tampered.href,
      expired,
      missing,
      traversal,
      `https://media.test/?list-type=2`,
    ]
  ) {
    const res = await handle(
      new Request(url),
      env(b),
      context(),
      memoryCache(),
    );
    assertEquals(res.status, 404, url);
    assertEquals(await res.text(), "Not found");
  }
  const post = await handle(
    new Request(good, { method: "POST" }),
    env(b),
    context(),
    memoryCache(),
  );
  assertEquals(post.status, 404);
});

Deno.test("a range is answered with 206 and fills the cache from the start", async () => {
  const b = bucket({ [key]: bytes });
  const cache = memoryCache();
  const ctx = context();
  const res = await handle(
    new Request(await link(), { headers: { range: "bytes=0-1" } }),
    env(b),
    ctx,
    cache,
  );
  assertEquals(res.status, 206);
  assertEquals(res.headers.get("content-range"), "bytes 0-1/10");
  assertEquals(await res.text(), "01");
  await ctx.done();
  assertEquals(cache.keys.length, 1);
});

Deno.test("HEAD has headers and no body", async () => {
  const res = await handle(
    new Request(await link(), { method: "HEAD" }),
    env(bucket({ [key]: bytes })),
    context(),
    null,
  );
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-length"), "10");
  assertEquals(res.body, null);
});

// MARK: Blurred copies

const photo = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/p.jpg";

/** A stand-in for the Images binding that records what it was asked. */
function images(fail = false): ImagesBinding & { asked: unknown[] } {
  const b = {
    asked: [] as unknown[],
    input: (stream: ReadableStream<Uint8Array>) => ({
      transform: (t: unknown) => ({
        output: async (o: unknown) => {
          b.asked.push({ ...(t as object), ...(o as object) });
          if (fail) throw new Error("unsupported image");
          const original = await new Response(stream).text();
          return {
            response: () => new Response(`blurred(${original})`, { headers: { "content-type": "image/webp" } }),
          };
        },
      }),
    }),
  };
  return b;
}

async function blurLink(k = photo, mode = "l1", ttl = 3600): Promise<string> {
  const exp = Math.floor(Date.now() / 1000) + ttl;
  const { token, sig } = await sealBlurToken(secret, k, mode, "11111111-1111-4111-8111-111111111111", exp);
  return `https://media.test/b/${mode}/${token}?exp=${exp}&sig=${sig}`;
}

Deno.test("a blur link serves a small, strongly blurred WebP, then the CDN copy under an opaque id", async () => {
  const b = bucket({ [photo]: bytes });
  const img = images();
  const cache = memoryCache();
  const ctx = context();
  const res = await handle(new Request(await blurLink()), { ...env(b), IMAGES: img }, ctx, cache);
  assertEquals(res.status, 200);
  assertEquals(await res.text(), "blurred(0123456789)");
  assertEquals(res.headers.get("content-type"), "image/webp");
  assertEquals(res.headers.get("cache-control")?.startsWith("private, max-age="), true);
  assertEquals(res.headers.get("etag"), null, "nothing of the original file");
  assertEquals(img.asked, [{ width: 200, fit: "scale-down", blur: 50, format: "image/webp", quality: 60 }]);
  await ctx.done();
  assertEquals(cache.keys.length, 1);
  assertEquals(/^https:\/\/media\.test\/b\/l1\/[A-Za-z0-9_-]{43}$/.test(cache.keys[0]), true);
  assertEquals(cache.keys[0].includes("0b6f1f5e"), false, "no person in the cache key");

  // Another link to the same photo (another viewer, another quarter hour) is served from that copy.
  const again = await handle(new Request(await blurLink(photo, "l1", 3000)), { ...env(b), IMAGES: img }, ctx, cache);
  assertEquals(await again.text(), "blurred(0123456789)");
  assertEquals(b.gets, 1);
});

Deno.test("a blur link never serves the original", async () => {
  const b = bucket({ [photo]: bytes });
  const noBinding = await handle(new Request(await blurLink()), env(b), context(), memoryCache());
  assertEquals(noBinding.status, 404, "without the Images binding");
  const failed = await handle(new Request(await blurLink()), { ...env(b), IMAGES: images(true) }, context(), null);
  assertEquals(failed.status, 404, "when the transformation fails");
});

Deno.test("the same 404 for a tampered, expired, unknown-mode or non-photo blur link", async () => {
  const b = bucket({ [photo]: bytes, [key]: bytes });
  const e = { ...env(b), IMAGES: images() };
  const good = new URL(await blurLink());
  const variants: string[] = [];
  const tampered = new URL(good);
  tampered.searchParams.set("exp", String(Number(good.searchParams.get("exp")) + 900));
  variants.push(tampered.href);
  variants.push(good.href.replace("/b/l1/", "/b/l2/"));
  variants.push(good.href.replace(/sig=[^&]+/, "sig=" + "A".repeat(43)));
  variants.push(good.href.replace(/&sig=[^&]+/, ""));
  variants.push(good.href.replace("/b/l1/", "/b/l1/A"));
  variants.push(await blurLink(photo, "l1", -10));
  variants.push(await blurLink(photo, "zz"));
  variants.push(await blurLink(key)); // a video
  variants.push(await blurLink("u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/missing.jpg"));
  for (const v of variants) {
    const res = await handle(new Request(v), e, context(), null);
    assertEquals(res.status, 404, v);
    assertEquals(res.headers.get("cache-control"), "no-store");
  }
});

Deno.test("an ordinary link to the photo is not a way around the blur", async () => {
  // A blur link's signature does not open the sharp path: its key never appears, and the signature
  // is not an ordinary one.
  const link = new URL(await blurLink());
  const sharp = `https://media.test/${photo}?exp=${link.searchParams.get("exp")}&sig=${link.searchParams.get("sig")}`;
  const res = await handle(new Request(sharp), env(bucket({ [photo]: bytes })), context(), null);
  assertEquals(res.status, 404);
});

const photoKey = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/a1b2.jpg";

Deno.test("a rendition is made once, kept in R2, then served from there in any data centre", async () => {
  const b = bucket({ [photoKey]: bytes });
  const img = images();
  const ctx = context();
  const res = await handle(
    new Request(`${await link(photoKey)}&w=1080`),
    { ...env(b), IMAGES: img },
    ctx,
    memoryCache(),
  );
  assertEquals(res.status, 200);
  assertEquals(await res.text(), "blurred(0123456789)");
  await ctx.done();
  assertEquals(b.puts, [renditionKey(photoKey, 1080)]);
  assertEquals(img.asked, [{ width: 1080, fit: "scale-down", format: "image/webp", quality: 70 }]);

  // Another data centre: an empty edge cache, the copy kept in R2.
  const elsewhere = await handle(
    new Request(`${await link(photoKey)}&w=1080`),
    { ...env(b), IMAGES: img },
    context(),
    memoryCache(),
  );
  assertEquals(await elsewhere.text(), "blurred(0123456789)");
  assertEquals(img.asked.length, 1, "not transformed again");
});

Deno.test("a rendition whose original is gone is deleted, never served", async () => {
  const kept = renditionKey(photoKey, 320);
  const b = bucket({ [kept]: bytes });
  const ctx = context();
  const res = await handle(new Request(`${await link(photoKey)}&w=320`), { ...env(b), IMAGES: images() }, ctx, null);
  assertEquals(res.status, 404);
  await res.body?.cancel();
  await ctx.done();
  assertEquals(b.deletes, [kept]);
});

Deno.test("a rendition key is never a link of its own", async () => {
  const b = bucket({ [renditionKey(photoKey, 320)]: bytes });
  const res = await handle(new Request(await link(renditionKey(photoKey, 320))), env(b), context(), null);
  assertEquals(res.status, 404);
  await res.body?.cancel();
});

Deno.test("the Worker's widths, quality and keys are the ones deleted with a photo", () => {
  assertEquals(WIDTHS, deletion.RENDITION_WIDTHS);
  assertEquals(RENDITION_QUALITY, deletion.RENDITION_QUALITY);
  for (const width of WIDTHS) assertEquals(renditionKey(photoKey, width), deletion.renditionKey(photoKey, width));
  assertEquals(renditionKey(photoKey, 1440), `${photoKey}.w1440.q70.webp`);
});
