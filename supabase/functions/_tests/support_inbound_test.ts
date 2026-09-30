// support-inbound: only the support mail Worker (its shared secret) may post, what it posts reaches
// receive_support_email as it should, and the database's refusals become answers the Worker acts on.
//
//   cd supabase/functions && deno test --allow-env --allow-read=. _tests/support_inbound_test.ts
//
// No network: fetch answers the RPC from a script and records what it was asked.
import { assertEquals } from "jsr:@std/assert@1";

const ENV: Record<string, string> = {
  SUPABASE_URL: "http://supabase.test",
  SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
  SUPABASE_SECRET_KEYS: "",
  SUPPORT_INBOUND_SECRET: "test-inbound-secret",
};
for (const [name, value] of Object.entries(ENV)) Deno.env.set(name, value);

const rpcs: Record<string, unknown>[] = [];
/** What receive_support_email answers next: its result, or a refusal (status 400 and its hint). */
let answer: { data?: unknown; hint?: string } = {};

globalThis.fetch = async (input: Request | URL | string, init?: RequestInit): Promise<Response> => {
  const request = input instanceof Request ? input : new Request(String(input), init);
  const path = new URL(request.url).pathname;
  if (request.method === "POST" && path === "/rest/v1/rpc/receive_support_email") {
    rpcs.push(await request.json());
    if (answer.hint) {
      return Response.json({ code: "P0001", message: "refused", hint: answer.hint, details: null }, { status: 400 });
    }
    return Response.json(answer.data);
  }
  return Promise.reject(new Error(`unexpected fetch in a test: ${request.method} ${path}`));
};

type Handler = (req: Request) => Response | Promise<Response>;
let handler: Handler | undefined;
const serve = Deno.serve;
// deno-lint-ignore no-explicit-any
(Deno as any).serve = (h: Handler) => {
  handler = h;
  return { finished: Promise.resolve(), shutdown: () => Promise.resolve(), ref() {}, unref() {} };
};
await import("../support-inbound/index.ts");
Deno.serve = serve;

async function post(body: unknown, secret = "test-inbound-secret") {
  rpcs.length = 0;
  const response = await handler!(
    new Request("http://functions.test/support-inbound", {
      method: "POST",
      headers: { "x-support-inbound-secret": secret, "content-type": "application/json" },
      body: typeof body === "string" ? body : JSON.stringify(body),
    }),
  );
  return { status: response.status, body: await response.json() };
}

const email = {
  from: "Lea@Drafft.so",
  subject: "Re: Help [DR-ABC123]",
  text: "Still stuck",
  reference: "DR-ABC123",
  messageId: "<m1@mail.test>",
  attachments: ["screenshot.png"],
  authentication: "spf=pass dkim=pass dmarc=pass",
};

Deno.test("without the Worker's secret: 401, nothing read", async () => {
  answer = { data: {} };
  assertEquals((await post(email, "wrong")).status, 401);
  assertEquals((await post(email, "")).status, 401);
  assertEquals(rpcs, []);
});

Deno.test("an email: passed on as received, attachments by name only, the database's answer returned", async () => {
  answer = { data: { outcome: "appended", reference: "DR-ABC123", truncated: false } };
  const { status, body } = await post(email);
  assertEquals([status, body], [200, { outcome: "appended", reference: "DR-ABC123", truncated: false }]);
  assertEquals(rpcs, [{
    p_from: "Lea@Drafft.so",
    p_subject: "Re: Help [DR-ABC123]",
    p_body: "Still stuck",
    p_reference: "DR-ABC123",
    p_message_id: "<m1@mail.test>",
    p_context: { attachments: ["screenshot.png"], authentication: "spf=pass dkim=pass dmarc=pass" },
  }]);
});

Deno.test("no reference, no Message-ID: null, and the context stays small", async () => {
  answer = { data: { outcome: "created", reference: "DR-NEW234", truncated: false } };
  const many = Array.from({ length: 30 }, (_, i) => `${"x".repeat(300)}-${i}.pdf`);
  await post({ from: "new@drafft.so", subject: "Hello", text: "A question", attachments: many });
  assertEquals([rpcs[0].p_reference, rpcs[0].p_message_id], [null, null]);
  const names = (rpcs[0].p_context as { attachments: string[] }).attachments;
  assertEquals([names.length, names[0].length], [10, 100]);
});

Deno.test("what can't be a message: 400; over the limits: 429; too big: 413", async () => {
  answer = { data: {} };
  assertEquals((await post({ ...email, from: "not an address" })).body.code, "invalid_email");
  assertEquals((await post("{")).body.code, "invalid_json");
  answer = { hint: "empty_message" };
  assertEquals((await post({ ...email, text: "", subject: "" })).status, 400);
  answer = { hint: "too_many_requests" };
  assertEquals((await post(email)).status, 429);
  assertEquals((await post({ ...email, text: "x".repeat(300_000) })).status, 413);
});
