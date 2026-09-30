import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { type Env, type IncomingEmail, receive } from "./index.ts";

const env: Env = {
  SUPPORT_INBOUND_URL: "https://project.supabase.test/functions/v1/support-inbound",
  SUPPORT_INBOUND_SECRET: "inbound-secret",
  FALLBACK_ADDRESS: "team@drafft.so",
};

/** An email as Email Routing hands it over, recording where it is forwarded. */
function incoming(raw: string, options: { from?: string; headers?: Record<string, string>; forward?: "fail" } = {}) {
  const forwarded: { to: string; reason: string | null }[] = [];
  const email: IncomingEmail = {
    from: options.from ?? "lea@drafft.so",
    to: "support@getdrafft.com",
    headers: new Headers({ "authentication-results": "mx.cloudflare.net; spf=pass; dkim=pass", ...options.headers }),
    raw: new Response(raw.replace(/\n/g, "\r\n")).body!,
    rawSize: raw.length,
    forward(to: string, headers?: Headers) {
      if (options.forward === "fail") return Promise.reject(new Error("destination address not verified"));
      forwarded.push({ to, reason: headers?.get("x-drafft-support") ?? null });
      return Promise.resolve({});
    },
  };
  return { email, forwarded };
}

/** support-inbound, answering `status` and `body`; what it was sent is recorded. */
function inbound(status: number, body: unknown) {
  const posts: { headers: Headers; body: Record<string, unknown> }[] = [];
  const fake = (_url: string | URL | Request, init?: RequestInit) => {
    posts.push({ headers: new Headers(init?.headers), body: JSON.parse(String(init?.body)) });
    return Promise.resolve(Response.json(body, { status }));
  };
  return { posts, fetch: fake as typeof fetch };
}

const reply = `From: Lea <lea@drafft.so>
To: support@getdrafft.com
Subject: Re: Help [DR-ABC234]
Message-ID: <m1@mail.drafft.so>
Content-Type: text/plain; charset=utf-8

Still stuck, sorry.

On Mon, 30 Sep 2026 at 10:00, drafft <no-reply@mail.getdrafft.com> wrote:
> Try again?
`;

Deno.test("a reply: posted with the secret, what they wrote and the reference; nothing forwarded", async () => {
  const { email, forwarded } = incoming(reply);
  const fn = inbound(200, { outcome: "appended", reference: "DR-ABC234", truncated: false });
  assertEquals(await receive(email, env, fn.fetch), "filed");
  assertEquals(fn.posts[0].headers.get("x-support-inbound-secret"), "inbound-secret");
  assertEquals(fn.posts[0].body, {
    from: "lea@drafft.so",
    subject: "Re: Help [DR-ABC234]",
    text: "Still stuck, sorry.",
    reference: "DR-ABC234",
    messageId: "<m1@mail.drafft.so>",
    attachments: [],
    authentication: "mx.cloudflare.net; spf=pass; dkim=pass",
  });
  assertEquals(forwarded, []);
});

Deno.test("the sender is the envelope's, never a From header anyone can write", async () => {
  const { email } = incoming(reply.replace("From: Lea <lea@drafft.so>", "From: Lea <lea@drafft.so>"), {
    from: "mallory@evil.example",
  });
  const fn = inbound(200, { outcome: "created", reference: "DR-NEW234", truncated: false });
  await receive(email, env, fn.fetch);
  assertEquals(fn.posts[0].body.from, "mallory@evil.example");
});

Deno.test("attachments: filed by name, and the whole email kept at the fallback address", async () => {
  const raw = `From: lea@drafft.so
To: support@getdrafft.com
Subject: Screenshot
Message-ID: <m2@mail.drafft.so>
Content-Type: multipart/mixed; boundary="b"

--b
Content-Type: text/plain

Here it is.
--b
Content-Type: image/png; name="screen.png"
Content-Disposition: attachment; filename="screen.png"
Content-Transfer-Encoding: base64

iVBORw0KGgo=
--b--
`;
  const { email, forwarded } = incoming(raw);
  const fn = inbound(200, { outcome: "created", reference: "DR-NEW234", truncated: false });
  assertEquals(await receive(email, env, fn.fetch), "filed, copy kept");
  assertEquals([fn.posts[0].body.text, fn.posts[0].body.attachments, fn.posts[0].body.reference], [
    "Here it is.",
    ["screen.png"],
    null,
  ]);
  assertEquals(forwarded, [{
    to: "team@drafft.so",
    reason: "filed as DR-NEW234, not all of it: 1 attachment(s)",
  }]);
});

Deno.test("a text cut to size by the function: filed, and the whole email kept", async () => {
  const { email, forwarded } = incoming(reply);
  const fn = inbound(200, { outcome: "appended", reference: "DR-ABC234", truncated: true });
  assertEquals(await receive(email, env, fn.fetch), "filed, copy kept");
  assertEquals(forwarded[0].reason, "filed as DR-ABC234, not all of it: text cut to size");
});

Deno.test("the function refusing, failing or unreachable: the email goes to the fallback address", async () => {
  for (const status of [400, 401, 429, 500]) {
    const { email, forwarded } = incoming(reply);
    assertEquals(await receive(email, env, inbound(status, { code: "x" }).fetch), "kept");
    assertEquals(forwarded[0].to, "team@drafft.so");
    assertEquals(forwarded[0].reason?.startsWith(`not filed: support-inbound answered ${status}`), true);
  }
  const { email, forwarded } = incoming(reply);
  const down = () => Promise.reject(new TypeError("network connection lost"));
  assertEquals(await receive(email, env, down as typeof fetch), "kept");
  assertEquals(forwarded[0].reason, "not filed: TypeError: network connection lost");
});

Deno.test("an auto-reply is never filed (no request per out-of-office), only kept", async () => {
  const { email, forwarded } = incoming(reply, { headers: { "auto-submitted": "auto-replied" } });
  const fn = inbound(200, {});
  assertEquals(await receive(email, env, fn.fetch), "kept");
  assertEquals(fn.posts, []);
  assertEquals(forwarded[0].reason, "not filed: auto-submitted: auto-replied");
});

Deno.test("nowhere to keep it either: the Worker fails, so Email Routing refuses the email", async () => {
  const { email } = incoming(reply, { forward: "fail" });
  await assertRejects(() => receive(email, env, inbound(500, {}).fetch), Error, "not verified");
});
