// Authentication of the exposed Edge Functions (all `verify_jwt = false` in config.toml): each one checks
// its caller itself, and a request that fails the check gets a 401 before any work is done.
//
//   cd supabase/functions && deno test --allow-env --allow-read=. _tests/
//
// No network: fetch is replaced, and any call a test doesn't expect fails it. Each function's index.ts is
// imported as is, with Deno.serve replaced to capture its handler instead of listening.
import { Webhook } from "npm:standardwebhooks@1.0.0";

// Test values only, set before any function module reads them.
const ENV: Record<string, string> = {
  SUPABASE_URL: "http://supabase.test",
  SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
  SUPABASE_SECRET_KEYS: "",
  DB_EVENTS_SECRET: "test-db-events-secret",
  REVENUECAT_WEBHOOK_AUTH: "Bearer test-revenuecat-auth",
  STREAM_API_KEY: "test-stream-key",
  STREAM_API_SECRET: "test-stream-secret",
  SEND_EMAIL_HOOK_SECRET: `v1,whsec_${btoa("test-send-email-hook-secret")}`,
  SEND_SMS_HOOK_SECRET: `v1,whsec_${btoa("test-send-sms-hook-secret")}`,
};
for (const [name, value] of Object.entries(ENV)) Deno.env.set(name, value);

// Every outgoing request lands here. Only Auth's "who is this token" is answered (always: not valid);
// anything else is recorded and fails the test that caused it.
const unexpected: string[] = [];
globalThis.fetch = (input: Request | URL | string): Promise<Response> => {
  const url = input instanceof Request ? input.url : String(input);
  if (url === `${ENV.SUPABASE_URL}/auth/v1/user`) {
    return Promise.resolve(Response.json({ code: 401, error_code: "bad_jwt", msg: "invalid JWT" }, { status: 401 }));
  }
  unexpected.push(url);
  return Promise.reject(new Error(`unexpected fetch in a test: ${url}`));
};

/** Deep enough for statuses and URL lists; no dependency, so deno.lock stays the functions' own. */
function assertEquals<T>(actual: T, expected: T, message = "") {
  const [a, e] = [JSON.stringify(actual), JSON.stringify(expected)];
  if (a !== e) throw new Error(`${message ? `${message}: ` : ""}expected ${e}, got ${a}`);
}

type Handler = (req: Request) => Response | Promise<Response>;
const handlers = new Map<string, Handler>();

/** The handler a function's index.ts gives Deno.serve, without starting a server. */
async function load(name: string): Promise<Handler> {
  const loaded = handlers.get(name);
  if (loaded) return loaded;
  const serve = Deno.serve;
  let captured: Handler | undefined;
  // deno-lint-ignore no-explicit-any
  (Deno as any).serve = (handler: Handler) => {
    captured = handler;
    return { finished: Promise.resolve(), shutdown: () => Promise.resolve(), ref() {}, unref() {} };
  };
  try {
    await import(`../${name}/index.ts`);
  } finally {
    Deno.serve = serve;
  }
  if (!captured) throw new Error(`${name} didn't call Deno.serve`);
  handlers.set(name, captured);
  return captured;
}

/** Calls a function and returns its status; fails on any network call it made. */
async function status(name: string, init: RequestInit): Promise<number> {
  unexpected.length = 0;
  const handler = await load(name);
  const response = await handler(new Request(`http://functions.test/${name}`, { method: "POST", ...init }));
  await response.body?.cancel();
  assertEquals(unexpected, [], `${name} made network calls`);
  return response.status;
}

/** Standard Webhooks headers, as Supabase Auth signs its hooks. */
function signHook(secret: string, body: string): Record<string, string> {
  const id = `msg_${crypto.randomUUID()}`;
  const timestamp = new Date();
  const signature = new Webhook(secret.replace("v1,whsec_", "")).sign(id, timestamp, body);
  return {
    "webhook-id": id,
    "webhook-timestamp": String(Math.floor(timestamp.getTime() / 1000)),
    "webhook-signature": signature,
  };
}

/** X-Signature as Stream signs its webhooks: HMAC-SHA256 of the body with the API secret, in hex. */
async function signStream(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return Array.from(new Uint8Array(mac), (b) => b.toString(16).padStart(2, "0")).join("");
}

const event = JSON.stringify({ id: 1, event: "test.none", payload: {} });

Deno.test("db-events: no secret header → 401", async () => {
  assertEquals(await status("db-events", { body: event }), 401);
});

Deno.test("db-events: wrong secret → 401", async () => {
  assertEquals(await status("db-events", { body: event, headers: { "x-webhook-secret": "not-the-secret" } }), 401);
});

Deno.test("db-events: the right secret gets past the check", async () => {
  // Invalid JSON after the check: a 400 shows the secret was accepted, without reaching the database.
  const headers = { "x-webhook-secret": ENV.DB_EVENTS_SECRET };
  assertEquals(await status("db-events", { body: "{", headers }), 400);
});

Deno.test("revenuecat-webhook: no Authorization → 401", async () => {
  assertEquals(await status("revenuecat-webhook", { body: "{}" }), 401);
});

Deno.test("revenuecat-webhook: wrong Authorization → 401", async () => {
  const wrong = ENV.REVENUECAT_WEBHOOK_AUTH.slice(0, -1) + "x"; // same length, last character differs
  assertEquals(await status("revenuecat-webhook", { body: "{}", headers: { authorization: wrong } }), 401);
});

Deno.test("revenuecat-webhook: the right Authorization gets past the check", async () => {
  const headers = { authorization: ENV.REVENUECAT_WEBHOOK_AUTH };
  assertEquals(await status("revenuecat-webhook", { body: "{}", headers }), 400); // missing_event
});

const reaction = JSON.stringify({ type: "message.new" });

Deno.test("stream-webhook: no signature → 401", async () => {
  assertEquals(await status("stream-webhook", { body: reaction }), 401);
});

Deno.test("stream-webhook: signature with another secret → 401", async () => {
  const headers = { "x-signature": await signStream("another-secret", reaction) };
  assertEquals(await status("stream-webhook", { body: reaction, headers }), 401);
});

Deno.test("stream-webhook: signature of another body → 401", async () => {
  const headers = { "x-signature": await signStream(ENV.STREAM_API_SECRET, `${reaction} `) };
  assertEquals(await status("stream-webhook", { body: reaction, headers }), 401);
});

Deno.test("stream-webhook: a valid signature gets past the check", async () => {
  // Not a reaction event: acknowledged without any other call.
  const headers = { "x-signature": await signStream(ENV.STREAM_API_SECRET, reaction) };
  assertEquals(await status("stream-webhook", { body: reaction, headers }), 200);
});

const authHooks = [
  { name: "auth-email", secret: ENV.SEND_EMAIL_HOOK_SECRET },
  { name: "auth-sms", secret: ENV.SEND_SMS_HOOK_SECRET },
];
const hookBody = JSON.stringify({ user: { id: "00000000-0000-0000-0000-000000000000" }, sms: { otp: "123456" } });

for (const { name, secret } of authHooks) {
  Deno.test(`${name}: no signature → 401`, async () => {
    assertEquals(await status(name, { body: hookBody }), 401);
  });

  Deno.test(`${name}: signed with another secret → 401`, async () => {
    const headers = signHook(`v1,whsec_${btoa("another-secret")}`, hookBody);
    assertEquals(await status(name, { body: hookBody, headers }), 401);
  });

  Deno.test(`${name}: body changed after signing → 401`, async () => {
    const headers = signHook(secret, hookBody);
    assertEquals(await status(name, { body: hookBody.replace("123456", "654321"), headers }), 401);
  });
}

Deno.test("auth-sms: a valid signature gets past the check", async () => {
  // Not a phone change: refused with 403 before any send.
  const headers = signHook(ENV.SEND_SMS_HOOK_SECRET, hookBody);
  assertEquals(await status("auth-sms", { body: hookBody, headers }), 403);
});

// Called by the app with the person's access token (requireUser).
const userFunctions = ["chat-media", "delete-account", "device-check", "media-upload-url", "stream-token"];

for (const name of userFunctions) {
  Deno.test(`${name}: no token → 401`, async () => {
    assertEquals(await status(name, { body: "{}" }), 401);
  });

  Deno.test(`${name}: a token Auth doesn't accept → 401`, async () => {
    const headers = { authorization: "Bearer not-a-valid-token" };
    assertEquals(await status(name, { body: "{}", headers }), 401);
  });
}
