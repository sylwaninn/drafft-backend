import { assertEquals } from "jsr:@std/assert@1";
import { sign, verify } from "./signature.ts";

const secret = "test-signing-key";
const key = "u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/a.jpg";
const exp = 1700000000;
const at = (seconds: number) => seconds * 1000;

Deno.test("sign matches the shared vector (database, Edge Functions, sophros)", async () => {
  assertEquals(
    await sign(secret, key, exp),
    "I1YxT7hgXlCCw0Jkq79-oMnamOJOSSZn9MRs6E3d3Uw",
  );
});

Deno.test("verify accepts a link before it expires", async () => {
  assertEquals(
    await verify(
      secret,
      key,
      String(exp),
      await sign(secret, key, exp),
      at(exp - 3600),
    ),
    true,
  );
});

Deno.test("verify refuses an expired link", async () => {
  const sig = await sign(secret, key, exp);
  assertEquals(await verify(secret, key, String(exp), sig, at(exp)), false);
  assertEquals(await verify(secret, key, String(exp), sig, at(exp + 1)), false);
});

Deno.test("verify refuses a link further ahead than the backend issues", async () => {
  const far = exp + 3 * 3600;
  assertEquals(
    await verify(
      secret,
      key,
      String(far),
      await sign(secret, key, far),
      at(exp),
    ),
    false,
  );
});

Deno.test("verify refuses any alteration", async () => {
  const sig = await sign(secret, key, exp);
  const now = at(exp - 60);
  assertEquals(
    await verify(secret, key.replace("a.jpg", "b.jpg"), String(exp), sig, now),
    false,
    "another key",
  );
  assertEquals(
    await verify(secret, key, String(exp + 900), sig, now),
    false,
    "a later expiry",
  );
  assertEquals(
    await verify("another-key", key, String(exp), sig, now),
    false,
    "another secret",
  );
  const flipped = (sig[0] === "A" ? "B" : "A") + sig.slice(1);
  assertEquals(
    await verify(secret, key, String(exp), flipped, now),
    false,
    "another signature",
  );
  assertEquals(
    await verify(secret, key, String(exp), sig + "=", now),
    false,
    "padding",
  );
  assertEquals(await verify(secret, key, null, sig, now), false, "no expiry");
  assertEquals(
    await verify(secret, key, String(exp), null, now),
    false,
    "no signature",
  );
  assertEquals(
    await verify(secret, key, "17e8", sig, now),
    false,
    "not a plain number",
  );
  assertEquals(
    await verify("", key, String(exp), sig, now),
    false,
    "no secret configured",
  );
});
