// The verification SMS rules: phone-code (requestPhoneCode), Twilio Lookup (checkLine) and the Send SMS
// hook (smsHookDecision). No network: Lookup's fetch and the database calls are fakes.
//
//   cd supabase/functions && deno test --allow-env --allow-read=. _tests/
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { HttpError } from "../_shared/http.ts";
import { type PhoneCodeDeps, requestPhoneCode, smsHookDecision } from "../_shared/phone_code.ts";
import { checkLine, type LineCheck } from "../_shared/sms.ts";

const confirmed = { id: "u1", email_confirmed_at: "2026-09-28T10:00:00Z" };

function deps(line: LineCheck, auth: { status: number; errorCode?: string } = { status: 200 }) {
  const calls: string[] = [];
  const d: PhoneCodeDeps = {
    reserve: (user, phone, ip) => {
      calls.push(`reserve ${user} ${phone} ${ip}`);
      return Promise.resolve(7);
    },
    approve: (id) => {
      calls.push(`approve ${id}`);
      return Promise.resolve();
    },
    checkLine: (phone) => {
      calls.push(`lookup ${phone}`);
      return Promise.resolve(line);
    },
    startPhoneChange: (phone) => {
      calls.push(`auth ${phone}`);
      return Promise.resolve(auth);
    },
  };
  return { calls, deps: d };
}

async function refused(promise: Promise<unknown>, status: number, code: string) {
  const error = await assertRejects(() => promise, HttpError);
  assertEquals([error.status, error.code], [status, code]);
}

Deno.test("phone-code: an unconfirmed email gets email_unconfirmed, nothing reserved or sent", async () => {
  const f = deps("ok");
  await refused(requestPhoneCode({ id: "u1" }, "+33612345678", "203.0.113.7", f.deps), 403, "email_unconfirmed");
  await refused(
    requestPhoneCode({ id: "u1", email_confirmed_at: null }, "+33612345678", undefined, f.deps),
    403,
    "email_unconfirmed",
  );
  assertEquals(f.calls, []);
});

Deno.test("phone-code: not E.164 → phone_invalid, before any reservation", async () => {
  for (const phone of ["0612345678", "+0612345678", "+33 6 12 34 56 78", "+1234", 33612345678, undefined]) {
    const f = deps("ok");
    await refused(requestPhoneCode(confirmed, phone, undefined, f.deps), 400, "phone_invalid");
    assertEquals(f.calls, []);
  }
});

Deno.test("phone-code: any country goes to Lookup (no prefix list)", async () => {
  for (const phone of ["+81312345678", "+2348031234567", "+5511912345678", "+33612345678"]) {
    const f = deps("ok");
    await requestPhoneCode(confirmed, phone, "203.0.113.7", f.deps);
    assertEquals(f.calls, [`reserve u1 ${phone} 203.0.113.7`, `lookup ${phone}`, "approve 7", `auth ${phone}`]);
  }
});

Deno.test("phone-code: the limit is checked before Lookup", async () => {
  const f = deps("ok");
  f.deps.reserve = () => Promise.reject(new HttpError(429, "sms_limit"));
  await refused(requestPhoneCode(confirmed, "+33612345678", undefined, f.deps), 429, "sms_limit");
  assertEquals(f.calls, []);
});

Deno.test("phone-code: Lookup refusals, and Lookup down, send nothing (fail closed)", async () => {
  const cases: [LineCheck, number, string][] = [
    ["refused", 400, "phone_unsupported"],
    ["invalid", 400, "phone_invalid"],
    ["unavailable", 503, "phone_check_unavailable"],
  ];
  for (const [line, status, code] of cases) {
    const f = deps(line);
    await refused(requestPhoneCode(confirmed, "+33612345678", undefined, f.deps), status, code);
    assertEquals(f.calls, ["reserve u1 +33612345678 undefined", "lookup +33612345678"], line);
  }
});

Deno.test("phone-code: Auth's refusals keep stable codes", async () => {
  const cases: [{ status: number; errorCode?: string }, number, string][] = [
    [{ status: 422, errorCode: "phone_exists" }, 409, "phone_taken"],
    [{ status: 429, errorCode: "over_sms_send_rate_limit" }, 429, "sms_limit"],
    [{ status: 500, errorCode: "hook_timeout" }, 502, "sms_failed"],
  ];
  for (const [auth, status, code] of cases) {
    await refused(requestPhoneCode(confirmed, "+33612345678", undefined, deps("ok", auth).deps), status, code);
  }
});

// MARK: Lookup

function lookup(status: number, body: unknown) {
  const urls: string[] = [];
  const fake = (input: string | URL | Request) => {
    urls.push(String(input));
    return Promise.resolve(Response.json(body, { status }));
  };
  return { urls, fetch: fake as typeof fetch };
}

const hosted = "https://example.supabase.co";
const keys = { sid: "SK1", secret: "s", supabaseUrl: hosted };

Deno.test("lookup: only a mobile line is accepted", async () => {
  const types: [string | null | undefined, LineCheck][] = [
    ["mobile", "ok"],
    ["landline", "refused"],
    ["fixedVoip", "refused"],
    ["nonFixedVoip", "refused"],
    ["premium", "refused"],
    ["sharedCost", "refused"],
    ["tollFree", "refused"],
    ["personal", "refused"],
    ["uan", "refused"],
    ["unknown", "refused"],
    [null, "refused"],
    [undefined, "refused"],
  ];
  for (const [type, expected] of types) {
    const l = lookup(200, { valid: true, line_type_intelligence: { type, error_code: null } });
    assertEquals(await checkLine("+33612345678", { ...keys, fetch: l.fetch }), expected, String(type));
    assertEquals(l.urls, ["https://lookups.twilio.com/v2/PhoneNumbers/%2B33612345678?Fields=line_type_intelligence"]);
  }
});

Deno.test("lookup: an invalid number is invalid", async () => {
  assertEquals(await checkLine("+33612345678", { ...keys, fetch: lookup(200, { valid: false }).fetch }), "invalid");
  assertEquals(await checkLine("+33612345678", { ...keys, fetch: lookup(404, {}).fetch }), "invalid");
});

Deno.test("lookup: down, erroring or without a line type → unavailable", async () => {
  assertEquals(await checkLine("+33612345678", { ...keys, fetch: lookup(503, {}).fetch }), "unavailable");
  const noType = lookup(200, { valid: true, line_type_intelligence: { type: null, error_code: 60600 } });
  assertEquals(await checkLine("+33612345678", { ...keys, fetch: noType.fetch }), "unavailable");
  const throwing = (() => Promise.reject(new TypeError("network"))) as typeof fetch;
  assertEquals(await checkLine("+33612345678", { ...keys, fetch: throwing }), "unavailable");
});

Deno.test("lookup: no key on a hosted project fails closed; locally it is skipped", async () => {
  const l = lookup(200, {});
  assertEquals(
    await checkLine("+33612345678", { sid: undefined, secret: "s", supabaseUrl: hosted, fetch: l.fetch }),
    "unavailable",
  );
  const local = { sid: undefined, secret: undefined, supabaseUrl: "http://kong:8000", fetch: l.fetch };
  assertEquals(await checkLine("+33612345678", local), "ok");
  assertEquals(l.urls, []);
});

// MARK: Send SMS hook

function hookDeps(emailConfirmed: boolean, reserved: boolean) {
  const calls: string[] = [];
  return {
    calls,
    deps: {
      emailConfirmed: (id: string) => {
        calls.push(`email ${id}`);
        return Promise.resolve(emailConfirmed);
      },
      consume: (id: string, phone: string) => {
        calls.push(`consume ${id} ${phone}`);
        return Promise.resolve(reserved);
      },
    },
  };
}

const change = { id: "u1", new_phone: "33612345678", email_confirmed_at: "2026-09-28T10:00:00Z" };

Deno.test("auth-sms: not a phone change → 403, nothing read", async () => {
  const h = hookDeps(true, true);
  const d = await smsHookDecision({ user: { id: "u1" }, sms: { otp: "123456" } }, h.deps);
  assertEquals([d.send, !d.send && d.status], [false, 403]);
  assertEquals(h.calls, []);
});

Deno.test("auth-sms: email not confirmed → email_unconfirmed, whatever the reservation", async () => {
  const h = hookDeps(false, true);
  const d = await smsHookDecision({ user: { id: "u1", new_phone: "33612345678" }, sms: { otp: "1" } }, h.deps);
  assertEquals(d.send ? null : [d.status, d.message], [403, "email_unconfirmed"]);
  assertEquals(h.calls, ["email u1"]);
});

Deno.test("auth-sms: confirmed in the payload, with an approved reservation → sent to the E.164 number", async () => {
  const h = hookDeps(false, true);
  const d = await smsHookDecision({ user: change, sms: { otp: "123456", phone: "33612345678" } }, h.deps);
  assertEquals(d, { send: true, to: "+33612345678" });
  assertEquals(h.calls, ["consume u1 +33612345678"]);
});

Deno.test("auth-sms: confirmed but no reservation (asked of Auth directly) → not sent", async () => {
  const h = hookDeps(true, false);
  const d = await smsHookDecision({ user: change, sms: { otp: "123456" } }, h.deps);
  assertEquals(d.send ? null : [d.status, d.message], [403, "sms_not_reserved"]);
});

Deno.test("auth-sms: a number change from a confirmed account is still sent", async () => {
  const h = hookDeps(true, true);
  const user = { ...change, phone: "33700000000", new_phone: "447400123456" };
  const d = await smsHookDecision({ user, sms: { otp: "123456" } }, h.deps);
  assertEquals(d, { send: true, to: "+447400123456" });
});
