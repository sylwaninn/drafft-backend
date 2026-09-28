import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { HttpError } from "../_shared/http.ts";
import { siteverifyUrl, verifySignedOutCaptcha } from "../_shared/turnstile.ts";

const hosted = "https://example.supabase.co";
const req = () =>
  new Request("http://localhost/support", { method: "POST", headers: { "x-forwarded-for": "203.0.113.7, 10.0.0.1" } });

function siteverify(outcome: unknown) {
  const calls: { url: string; form: URLSearchParams }[] = [];
  const fake = (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), form: new URLSearchParams(String(init?.body)) });
    return Promise.resolve(Response.json(outcome));
  };
  return { calls, fetch: fake as typeof fetch };
}

async function refused(promise: Promise<void>, status: number, code: string) {
  const error = await assertRejects(() => promise, HttpError);
  assertEquals([error.status, error.code], [status, code]);
}

Deno.test("signed out without a token: captcha_required, Siteverify not called", async () => {
  const cf = siteverify({ success: true });
  await refused(
    verifySignedOutCaptcha(req(), null, undefined, { secret: "s", supabaseUrl: hosted, fetch: cf.fetch }),
    400,
    "captcha_required",
  );
  await refused(
    verifySignedOutCaptcha(req(), null, "x".repeat(2049), { secret: "s", supabaseUrl: hosted, fetch: cf.fetch }),
    400,
    "captcha_required",
  );
  assertEquals(cf.calls.length, 0);
});

Deno.test("signed out, Siteverify says no: captcha_failed", async () => {
  const cf = siteverify({ success: false, "error-codes": ["invalid-input-response"] });
  await refused(
    verifySignedOutCaptcha(req(), null, "token", { secret: "s", supabaseUrl: hosted, fetch: cf.fetch }),
    403,
    "captcha_failed",
  );
});

Deno.test("signed out, Siteverify says yes but for another hostname: captcha_failed", async () => {
  const cf = siteverify({ success: true, hostname: "evil.example" });
  await refused(
    verifySignedOutCaptcha(req(), null, "token", { secret: "s", supabaseUrl: hosted, fetch: cf.fetch }),
    403,
    "captcha_failed",
  );
});

Deno.test("signed out, Siteverify says yes: accepted, with secret, response, IP and idempotency key", async () => {
  const cf = siteverify({ success: true, hostname: "getdrafft.com" });
  await verifySignedOutCaptcha(req(), null, "token", { secret: "s", supabaseUrl: hosted, fetch: cf.fetch });
  assertEquals(cf.calls.length, 1);
  const { url, form } = cf.calls[0];
  assertEquals(url, siteverifyUrl);
  assertEquals([form.get("secret"), form.get("response"), form.get("remoteip")], ["s", "token", "203.0.113.7"]);
  assertEquals(form.get("idempotency_key")?.length, 36);
});

Deno.test("signed in without a token: no captcha", async () => {
  const cf = siteverify({ success: false });
  await verifySignedOutCaptcha(req(), "0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10", undefined, {
    secret: "s",
    supabaseUrl: hosted,
    fetch: cf.fetch,
  });
  assertEquals(cf.calls.length, 0);
});

Deno.test("no secret: refused when hosted, skipped locally", async () => {
  await refused(
    verifySignedOutCaptcha(req(), null, "token", { secret: undefined, supabaseUrl: hosted }),
    500,
    "captcha_not_configured",
  );
  await verifySignedOutCaptcha(req(), null, undefined, { secret: undefined, supabaseUrl: "http://kong:8000" });
});
