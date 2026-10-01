import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { blurCacheId, blurKeys, openBlurToken, sealBlurToken } from "./blur_token.ts";
import { sign } from "./signature.ts";

const secret = "test-signing-key";
const key = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/a.jpg";
const viewer = "11111111-1111-4111-8111-111111111111";
const exp = 1700000000;
const at = (seconds: number) => seconds * 1000;
const before = at(exp - 3600);

Deno.test("seal matches the shared vector (private.blur_url, blurred_likes.test.sql)", async () => {
  assertEquals(await sealBlurToken(secret, key, "l1", viewer, exp), {
    token:
      "rW0cnTaXrrj8Z4hQp97dJI-BgoGXMKE7ud653e6zZ9kmW6DUjgd8tDoDLA9qfMmGWGKf_wdJK8R83jleIk9RABcahaYnQ2NooyZ4YHeOVVw",
    sig: "KUDgBV_JAKiscRBVgqlwEbDSBKmt3jBcQ2eFuMe4otI",
  });
});

Deno.test("the token names neither the person nor the photo", async () => {
  const { token } = await sealBlurToken(secret, key, "l1", viewer, exp);
  const decoded = atob(token.replace(/-/g, "+").replace(/_/g, "/") + "==".slice(0, (4 - token.length % 4) % 4));
  assertEquals(token.includes("0b6f1f5e"), false);
  assertEquals(decoded.includes("0b6f1f5e"), false);
  assertEquals(decoded.includes("photos"), false);
});

Deno.test("open gives the key back before the link expires", async () => {
  const { token, sig } = await sealBlurToken(secret, key, "l1", viewer, exp);
  assertEquals(await openBlurToken(await blurKeys(secret), "l1", token, String(exp), sig, before), key);
});

Deno.test("a token differs per viewer and per expiry", async () => {
  const a = await sealBlurToken(secret, key, "l1", viewer, exp);
  const b = await sealBlurToken(secret, key, "l1", "22222222-2222-4222-8222-222222222222", exp);
  const c = await sealBlurToken(secret, key, "l1", viewer, exp + 900);
  assertNotEquals(a.token, b.token);
  assertNotEquals(a.token, c.token);
});

Deno.test("open refuses an expired link, or one further ahead than the backend issues", async () => {
  const keys = await blurKeys(secret);
  const { token, sig } = await sealBlurToken(secret, key, "l1", viewer, exp);
  assertEquals(await openBlurToken(keys, "l1", token, String(exp), sig, at(exp)), null);
  assertEquals(await openBlurToken(keys, "l1", token, String(exp), sig, at(exp + 1)), null);
  const far = exp + 3 * 3600;
  const later = await sealBlurToken(secret, key, "l1", viewer, far);
  assertEquals(await openBlurToken(keys, "l1", later.token, String(far), later.sig, before), null);
});

Deno.test("open refuses a changed expiry, mode, token or signature", async () => {
  const keys = await blurKeys(secret);
  const { token, sig } = await sealBlurToken(secret, key, "l1", viewer, exp);
  const flip = (s: string, i: number) => s.slice(0, i) + (s[i] === "A" ? "B" : "A") + s.slice(i + 1);
  assertEquals(await openBlurToken(keys, "l1", token, String(exp + 900), sig, before), null, "expiry");
  assertEquals(await openBlurToken(keys, "l2", token, String(exp), sig, before), null, "mode");
  assertEquals(await openBlurToken(keys, "", token, String(exp), sig, before), null, "no mode");
  assertEquals(await openBlurToken(keys, "l1", flip(token, 0), String(exp), sig, before), null, "iv");
  assertEquals(
    await openBlurToken(keys, "l1", flip(token, token.length - 2), String(exp), sig, before),
    null,
    "ciphertext",
  );
  assertEquals(await openBlurToken(keys, "l1", token.slice(0, -22), String(exp), sig, before), null, "truncated");
  assertEquals(await openBlurToken(keys, "l1", token, String(exp), flip(sig, 5), before), null, "signature");
  assertEquals(await openBlurToken(keys, "l1", token, String(exp), null, before), null, "no signature");
  assertEquals(await openBlurToken(keys, "l1", token, null, sig, before), null, "no expiry");
  assertEquals(await openBlurToken(keys, "l1", token, "1e10", sig, before), null, "not a number");
});

Deno.test("open refuses another secret, and an ordinary link's signature", async () => {
  const { token, sig } = await sealBlurToken(secret, key, "l1", viewer, exp);
  assertEquals(await openBlurToken(await blurKeys("other-key"), "l1", token, String(exp), sig, before), null);
  const ordinary = await sign(secret, `l1\n${token}`, exp);
  assertEquals(await openBlurToken(await blurKeys(secret), "l1", token, String(exp), ordinary, before), null);
});

Deno.test("the cache id is stable, opaque and per mode", async () => {
  const keys = await blurKeys(secret);
  const id = await blurCacheId(keys, "l1", key);
  assertEquals(id, await blurCacheId(keys, "l1", key));
  assertNotEquals(id, await blurCacheId(keys, "l2", key));
  assertEquals(/^[A-Za-z0-9_-]{43}$/.test(id) && !id.includes("0b6f1f5e"), true);
});
