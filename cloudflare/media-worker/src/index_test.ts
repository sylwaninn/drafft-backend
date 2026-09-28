import { assertEquals } from "jsr:@std/assert@1";
import { type Context, type EdgeCache, type Env, handle, type R2Bucket, type R2ObjectBody } from "./index.ts";
import { sign } from "./signature.ts";

const secret = "test-signing-key";
const key = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/videos/clip.mp4";
const bytes = new TextEncoder().encode("0123456789");

function bucket(
  objects: Record<string, Uint8Array>,
): R2Bucket & { gets: number } {
  const b = {
    gets: 0,
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
