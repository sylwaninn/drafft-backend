import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import { mediaExpiry, mediaSignature, signedMediaUrl } from "./media_url.ts";

const key = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/a.jpg";

Deno.test("mediaSignature matches the shared vector (database, Worker, sophros)", async () => {
  assertEquals(
    await mediaSignature("test-signing-key", key, 1700000000),
    "I1YxT7hgXlCCw0Jkq79-oMnamOJOSSZn9MRs6E3d3Uw",
  );
});

Deno.test("mediaExpiry is one hour to one hour and a quarter ahead, on a quarter hour", () => {
  const now = Date.UTC(2026, 8, 28, 10, 7, 30);
  const exp = mediaExpiry(now);
  assertEquals(exp % 900, 0);
  assertEquals(exp - now / 1000 >= 3600 && exp - now / 1000 < 4500, true);
});

Deno.test("signedMediaUrl signs when MEDIA_SIGNING_KEY is set, and not otherwise", async () => {
  Deno.env.set("MEDIA_PUBLIC_URL", "https://media.test/");
  Deno.env.delete("MEDIA_SIGNING_KEY");
  assertEquals(await signedMediaUrl(key), `https://media.test/${key}`);
  Deno.env.set("MEDIA_SIGNING_KEY", "test-signing-key");
  assertMatch(
    await signedMediaUrl(key),
    /^https:\/\/media\.test\/u\/.+\/photos\/a\.jpg\?exp=\d+&sig=[A-Za-z0-9_-]{43}$/,
  );
  Deno.env.delete("MEDIA_SIGNING_KEY");
});
