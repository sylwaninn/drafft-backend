import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  canWrite,
  judge,
  type Payload,
  PlayApiError,
  PlayAuthError,
  playIntegrityConfigured,
  requestHashFor,
  resetAccessToken,
  verify,
  writeBits,
} from "./playintegrity.ts";

const now = Date.UTC(2026, 9, 2, 12, 0, 0);
const expected = { packageName: "so.drafft.app", requestHash: "abc", now };

function payload(change: (p: Payload) => void = () => {}): Payload {
  const p: Payload = {
    requestDetails: { requestPackageName: "so.drafft.app", requestHash: "abc", timestampMillis: String(now - 5_000) },
    appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED" },
    deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_DEVICE_INTEGRITY"] },
  };
  change(p);
  return p;
}

function reason(p: Payload): string {
  const verdict = judge(p, expected);
  return verdict.ok ? "ok" : verdict.reason;
}

Deno.test("judge accepts a recent token for our app on a genuine device, and reads the bits", () => {
  assertEquals(judge(payload(), expected), { ok: true, bits: { bit0: false, bit1: false }, recall: false });
  const closed = payload((p) => {
    p.deviceIntegrity!.deviceRecall = { values: { bitFirst: true } };
  });
  assertEquals(judge(closed, expected), { ok: true, bits: { bit0: true, bit1: false }, recall: true });
  const held = payload((p) => {
    p.deviceIntegrity!.deviceRecall = { values: { bitSecond: true } };
  });
  assertEquals(judge(held, expected), { ok: true, bits: { bit0: false, bit1: true }, recall: true });
  const both = payload((p) => {
    p.deviceIntegrity!.deviceRecall = { values: { bitFirst: true, bitSecond: true } };
  });
  assertEquals(judge(both, expected), { ok: true, bits: { bit0: true, bit1: true }, recall: true });
});

Deno.test("judge says when the verdict has no deviceRecall at all", () => {
  const verdict = judge(payload(), expected);
  assert(verdict.ok && !verdict.recall);
  const empty = payload((p) => {
    p.deviceIntegrity!.deviceRecall = {};
  });
  const emptyVerdict = judge(empty, expected);
  assert(emptyVerdict.ok && emptyVerdict.recall);
});

Deno.test("judge refuses a token that isn't ours, bound to someone else, or too old", () => {
  assertEquals(reason(payload((p) => (p.requestDetails!.requestPackageName = "evil.app"))), "package");
  assertEquals(reason(payload((p) => (p.requestDetails!.requestHash = "other"))), "request_hash");
  assertEquals(reason(payload((p) => (p.requestDetails!.requestHash = undefined))), "request_hash");
  assertEquals(reason(payload((p) => (p.requestDetails!.timestampMillis = String(now - 11 * 60 * 1000)))), "token_age");
  assertEquals(reason(payload((p) => (p.requestDetails!.timestampMillis = String(now + 5 * 60 * 1000)))), "token_age");
  assertEquals(reason(payload((p) => (p.requestDetails!.timestampMillis = undefined))), "token_age");
  assertEquals(reason(payload((p) => (p.requestDetails!.timestampMillis = "abc"))), "token_age");
  assertEquals(reason({}), "package");
});

Deno.test("judge: the age window is ten minutes behind and one minute ahead, inclusive", () => {
  const at = (ms: number) => reason(payload((p) => (p.requestDetails!.timestampMillis = ms)));
  assertEquals(at(now - 10 * 60 * 1000), "ok");
  assertEquals(at(now - 10 * 60 * 1000 - 1), "token_age");
  assertEquals(at(now + 60_000), "ok");
  assertEquals(at(now + 60_001), "token_age");
});

Deno.test("judge says what it saw for the logs: the other package, the age", () => {
  const wrongPackage = judge(payload((p) => (p.requestDetails!.requestPackageName = "evil.app")), expected);
  assertEquals(wrongPackage, { ok: false, reason: "package", detail: "got evil.app" });
  const old = judge(payload((p) => (p.requestDetails!.timestampMillis = now - 700_000)), expected);
  assertEquals(old, { ok: false, reason: "token_age", detail: "700 s" });
});

Deno.test("judge refuses an app Play doesn't recognise and a device that isn't genuine", () => {
  assertEquals(reason(payload((p) => (p.appIntegrity!.appRecognitionVerdict = "UNRECOGNIZED_VERSION"))), "app");
  assertEquals(reason(payload((p) => (p.appIntegrity = undefined))), "app");
  assertEquals(reason(payload((p) => (p.deviceIntegrity!.deviceRecognitionVerdict = []))), "device");
  assertEquals(reason(payload((p) => (p.deviceIntegrity = undefined))), "device");
  assertEquals(
    reason(payload((p) => (p.deviceIntegrity!.deviceRecognitionVerdict = ["MEETS_VIRTUAL_INTEGRITY"]))),
    "device",
  );
  assertEquals(
    reason(payload((p) => (p.deviceIntegrity!.deviceRecognitionVerdict = ["MEETS_BASIC_INTEGRITY"]))),
    "device",
  );
  assertEquals(
    reason(payload((p) => (p.deviceIntegrity!.deviceRecognitionVerdict = ["MEETS_STRONG_INTEGRITY"]))),
    "ok",
  );
  assertEquals(
    reason(
      payload((
        p,
      ) => (p.deviceIntegrity!.deviceRecognitionVerdict = ["MEETS_BASIC_INTEGRITY", "MEETS_DEVICE_INTEGRITY"])),
    ),
    "ok",
  );
});

Deno.test("requestHashFor is the lowercase hex SHA-256 of the account's id as lowercase text", async () => {
  const id = "0B6F1F5E-8F0C-4A5E-9D3B-2F8A1C7E4D10";
  const hash = await requestHashFor(id);
  assertEquals(hash.length, 64);
  assertEquals(hash, await requestHashFor(id.toLowerCase()));
  assertEquals(await requestHashFor("a"), "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb");
});

Deno.test("canWrite: a token stored less than 14 days ago writes, an older one or an unreadable date doesn't", () => {
  const day = 24 * 60 * 60 * 1000;
  const stored = (daysAgo: number) => new Date(now - daysAgo * day).toISOString();
  assertEquals(canWrite(stored(13), now), true);
  assertEquals(canWrite(stored(15), now), false);
  assertEquals(canWrite("not a date", now), false);
});

// MARK: Google, behind a fetch stub

const pair = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"],
);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
const ACCOUNT = JSON.stringify({ client_email: "play@drafft-test.iam.gserviceaccount.com", private_key: pem });
const user = "0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10";

type Seen = { url: string; body: string; authorization: string | null };

/** Runs `run` with env set and Google replaced: `answer` gets each request and the number of the call to its host. */
async function withGoogle(
  answer: (host: "oauth" | "play", url: URL, n: number) => Response | Promise<Response>,
  run: (seen: Seen[]) => void | Promise<void>,
  env: Record<string, string | undefined> = {},
) {
  const real = globalThis.fetch;
  const vars: Record<string, string | undefined> = {
    SUPABASE_URL: "http://supabase.test",
    PLAY_INTEGRITY_SERVICE_ACCOUNT: ACCOUNT,
    PLAY_CLOUD_PROJECT_NUMBER: "710693749934",
    PLAY_PACKAGE_NAME: undefined,
    ...env,
  };
  const before = Object.fromEntries(Object.keys(vars).map((k) => [k, Deno.env.get(k)]));
  const apply = (values: Record<string, string | undefined>) => {
    for (const [k, v] of Object.entries(values)) {
      if (v === undefined) Deno.env.delete(k);
      else Deno.env.set(k, v);
    }
  };
  apply(vars);
  resetAccessToken();
  const seen: Seen[] = [];
  const counts = { oauth: 0, play: 0 };
  globalThis.fetch = async (input: Request | URL | string, init?: RequestInit) => {
    const request = input instanceof Request ? input : new Request(input, init);
    const url = new URL(request.url);
    assert(url.host === "oauth2.googleapis.com" || url.host === "playintegrity.googleapis.com", `unexpected ${url}`);
    const host = url.host === "oauth2.googleapis.com" ? "oauth" : "play";
    seen.push({ url: request.url, body: await request.text(), authorization: request.headers.get("authorization") });
    return await answer(host, url, ++counts[host]);
  };
  try {
    await run(seen);
  } finally {
    globalThis.fetch = real;
    resetAccessToken();
    apply(before);
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const signedIn = () => json({ access_token: "play-access", expires_in: 3600 });

async function decodes(forUser = user) {
  const hash = await requestHashFor(forUser);
  return json({
    tokenPayloadExternal: payload((p) => {
      p.requestDetails!.requestHash = hash;
      p.requestDetails!.timestampMillis = String(Date.now());
    }),
  });
}

Deno.test("playIntegrityConfigured needs both secrets", async () => {
  await withGoogle(() => signedIn(), () => {
    assertEquals(playIntegrityConfigured(), true);
  });
  await withGoogle(() => signedIn(), () => {
    assertEquals(playIntegrityConfigured(), false);
  }, { PLAY_CLOUD_PROJECT_NUMBER: undefined });
  await withGoogle(() => signedIn(), () => {
    assertEquals(playIntegrityConfigured(), false);
  }, { PLAY_INTEGRITY_SERVICE_ACCOUNT: undefined });
});

Deno.test("verify signs in, decodes the token for our package and judges it for the account", async () => {
  await withGoogle(
    async (host) => host === "oauth" ? signedIn() : await decodes(),
    async (seen) => {
      const verdict = await verify("integrity-token", user);
      assertEquals(verdict.ok, true);
      assertEquals(seen.length, 2);
      assertEquals(seen[0].url, "https://oauth2.googleapis.com/token");
      const form = new URLSearchParams(seen[0].body);
      assertEquals(form.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
      const claims = JSON.parse(atob(form.get("assertion")!.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
      assertEquals(claims.iss, "play@drafft-test.iam.gserviceaccount.com");
      assertEquals(claims.scope, "https://www.googleapis.com/auth/playintegrity");
      assertEquals(seen[1].url, "https://playintegrity.googleapis.com/v1/so.drafft.app:decodeIntegrityToken");
      assertEquals(seen[1].authorization, "Bearer play-access");
      assertEquals(JSON.parse(seen[1].body), { integrityToken: "integrity-token" });
    },
  );
});

Deno.test("verify refuses a token made for another account", async () => {
  await withGoogle(
    async (host) => host === "oauth" ? signedIn() : await decodes("11111111-1111-4111-8111-111111111111"),
    async () => {
      const verdict = await verify("integrity-token", user);
      assertEquals(verdict.ok, false);
      assertEquals(!verdict.ok && verdict.reason, "request_hash");
    },
  );
});

Deno.test("the access token is kept: two calls sign in once; PLAY_PACKAGE_NAME changes the path", async () => {
  await withGoogle(
    async (host) => host === "oauth" ? signedIn() : await decodes(),
    async (seen) => {
      await verify("one", user);
      await writeBits("two", { bit0: true });
      assertEquals(seen.filter((s) => s.url.includes("oauth2")).length, 1);
      assert(seen[2].url.startsWith("https://playintegrity.googleapis.com/v1/so.drafft.beta/"));
    },
    { PLAY_PACKAGE_NAME: "so.drafft.beta" },
  );
});

Deno.test("an answer without access_token is refused and not kept", async () => {
  await withGoogle(
    (host, _url, n) => host === "oauth" ? (n === 1 ? json({}) : signedIn()) : decodes(),
    async () => {
      await assertRejects(() => verify("t", user), PlayAuthError, "no access_token");
      assertEquals((await verify("t", user)).ok, true);
    },
  );
});

Deno.test("a 401 from Google signs in again once", async () => {
  await withGoogle(
    async (host, _url, n) =>
      host === "oauth" ? signedIn() : n === 1 ? json({ error: "expired" }, 401) : await decodes(),
    async (seen) => {
      assertEquals((await verify("t", user)).ok, true);
      assertEquals(seen.filter((s) => s.url.includes("oauth2")).length, 2);
    },
  );
});

Deno.test("a refused sign-in or a bad key is a PlayAuthError, a refused decode a PlayApiError", async () => {
  await withGoogle(() => json({ error: "invalid_grant" }, 400), async () => {
    await assertRejects(() => verify("t", user), PlayAuthError, "google sign-in 400");
  });
  await withGoogle(() => signedIn(), async () => {
    await assertRejects(() => verify("t", user), PlayAuthError, "is not the JSON key");
  }, { PLAY_INTEGRITY_SERVICE_ACCOUNT: "not json" });
  await withGoogle(() => signedIn(), async () => {
    await assertRejects(() => verify("t", user), PlayAuthError, "no client_email or private_key");
  }, { PLAY_INTEGRITY_SERVICE_ACCOUNT: "{}" });
  await withGoogle(
    (host) => host === "oauth" ? signedIn() : json({ error: { message: "bad token" } }, 400),
    async () => {
      const error = await assertRejects(() => verify("t", user), PlayApiError);
      assertEquals((error as PlayApiError).status, 400);
      assertEquals((error as PlayApiError).step, "decode");
    },
  );
  await withGoogle((host) => host === "oauth" ? signedIn() : json({}), async () => {
    await assertRejects(() => verify("t", user), PlayApiError, "no payload");
  });
});

Deno.test("writeBits sends only the bits it is given, false included, and nothing for no change", async () => {
  await withGoogle(
    (host) => host === "oauth" ? signedIn() : json({}),
    async (seen) => {
      await writeBits("tok", { bit0: true });
      await writeBits("tok", { bit1: false });
      await writeBits("tok", { bit0: false, bit1: true });
      await writeBits("tok", {});
      const writes = seen.filter((s) => s.url.endsWith("/deviceRecall:write"));
      assertEquals(writes.length, 3);
      assertEquals(JSON.parse(writes[0].body), { integrityToken: "tok", newValues: { bitFirst: true } });
      assertEquals(JSON.parse(writes[1].body), { integrityToken: "tok", newValues: { bitSecond: false } });
      assertEquals(JSON.parse(writes[2].body), {
        integrityToken: "tok",
        newValues: { bitFirst: false, bitSecond: true },
      });
    },
  );
  await withGoogle((host) => host === "oauth" ? signedIn() : json({ error: "no" }, 403), async () => {
    await assertRejects(() => writeBits("tok", { bit0: true }), PlayApiError, "play integrity write 403");
  });
});
