// The Android half of device-check, with Supabase and Google replaced by a small world (every RPC and every
// Google call is recorded):
//
//   cd supabase/functions && deno test --allow-env --allow-read=. device-check/
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";

const pair = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"],
);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;

const ENV: Record<string, string> = {
  SUPABASE_URL: "http://supabase.test",
  SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
  SUPABASE_SECRET_KEYS: "",
  PLAY_INTEGRITY_SERVICE_ACCOUNT: JSON.stringify({
    client_email: "play@drafft-test.iam.gserviceaccount.com",
    private_key: pem,
  }),
  PLAY_CLOUD_PROJECT_NUMBER: "710693749934",
};
for (const [name, value] of Object.entries(ENV)) Deno.env.set(name, value);
Deno.env.delete("PLAY_PACKAGE_NAME");

// Imported after the environment: supabase.ts builds its client when it loads.
const { androidCheck } = await import("./android.ts");
const { HttpError } = await import("../_shared/http.ts");
const { requestHashFor, resetAccessToken } = await import("../_shared/playintegrity.ts");

const user = "0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10";
const token = "t".repeat(40);

type Bits = { bitFirst?: boolean; bitSecond?: boolean };
type Row = Record<string, unknown>;

const world = {
  rpc: [] as { name: string; args: Row }[],
  rpcResults: {} as Record<string, unknown>,
  failRpc: [] as string[],
  /** What Google's decode says: the device verdicts and the Device recall bits. */
  device: ["MEETS_DEVICE_INTEGRITY"] as string[],
  bits: {} as Bits,
  decodeStatus: 200,
  writeStatus: 200,
  signInStatus: 200,
  decodes: 0,
  writes: [] as Row[],
  /** Another account's token: the hash won't match. */
  otherHash: false,
};

const now = Date.now();
const hoursAgo = (h: number) => new Date(now - h * 3600_000).toISOString();

function reset() {
  world.rpc = [];
  world.failRpc = [];
  world.device = ["MEETS_DEVICE_INTEGRITY"];
  world.bits = {};
  world.decodeStatus = 200;
  world.writeStatus = 200;
  world.signInStatus = 200;
  world.decodes = 0;
  world.writes = [];
  world.otherHash = false;
  world.rpcResults = {
    device_check_begin: [{ standing: "ok", verified_at: null, has_pending: false }],
    record_device_check: "check",
    device_check_take_pending: [{ bit0: null, bit1: null }],
    device_check_set_pending: null,
    device_flagged: null,
  };
  resetAccessToken();
}

function respond(body: unknown, status = 200): Response {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

globalThis.fetch = async (input: Request | URL | string, init?: RequestInit): Promise<Response> => {
  const request = input instanceof Request ? input : new Request(input, init);
  const url = new URL(request.url);
  const text = request.method === "GET" ? "" : await request.text();
  if (url.host === "supabase.test" && url.pathname.startsWith("/rest/v1/rpc/")) {
    const name = url.pathname.slice("/rest/v1/rpc/".length);
    world.rpc.push({ name, args: text ? JSON.parse(text) : {} });
    if (world.failRpc.includes(name)) return respond({ message: "connection reset" }, 500);
    if (name === "device_check_begin" && world.rpcResults.tooMany) {
      return respond({ code: "P0001", message: "too many device checks", hint: "too_many_requests" }, 400);
    }
    return respond(world.rpcResults[name] ?? null);
  }
  if (url.host === "oauth2.googleapis.com") {
    return world.signInStatus === 200
      ? respond({ access_token: "play-access", expires_in: 3600 })
      : respond({ error: "invalid_grant" }, world.signInStatus);
  }
  if (url.host === "playintegrity.googleapis.com") {
    if (url.pathname.endsWith(":decodeIntegrityToken")) {
      world.decodes++;
      if (world.decodeStatus !== 200) return respond({ error: { message: "bad" } }, world.decodeStatus);
      const hash = await requestHashFor(world.otherHash ? "11111111-1111-4111-8111-111111111111" : user);
      return respond({
        tokenPayloadExternal: {
          requestDetails: {
            requestPackageName: "so.drafft.app",
            requestHash: hash,
            timestampMillis: String(Date.now()),
          },
          appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED" },
          deviceIntegrity: { deviceRecognitionVerdict: world.device, deviceRecall: { values: world.bits } },
        },
      });
    }
    if (url.pathname.endsWith("/deviceRecall:write")) {
      world.writes.push(JSON.parse(text).newValues);
      return world.writeStatus === 200 ? respond({}) : respond({ error: { message: "no" } }, world.writeStatus);
    }
  }
  throw new Error(`unexpected request ${request.method} ${request.url}`);
};

/** Runs `run` with console.error and console.warn collected. */
async function logged(run: () => Promise<void>): Promise<{ errors: string[]; warnings: string[] }> {
  const { error, warn, log } = console;
  const errors: string[] = [];
  const warnings: string[] = [];
  console.error = (...args: unknown[]) => void errors.push(args.map(String).join(" "));
  console.warn = (...args: unknown[]) => void warnings.push(args.map(String).join(" "));
  console.log = () => {};
  try {
    await run();
  } finally {
    Object.assign(console, { error, warn, log });
  }
  return { errors, warnings };
}

const calls = (name: string) => world.rpc.filter((r) => r.name === name);

Deno.test("androidCheck: without its secrets nothing is asked of Google or stored", async () => {
  reset();
  Deno.env.delete("PLAY_CLOUD_PROJECT_NUMBER");
  try {
    const { warnings } = await logged(async () => {
      const res = await androidCheck(user, token);
      assertEquals(res.status, 204);
    });
    assertEquals(world.rpc, []);
    assertEquals(world.decodes, 0);
    assert(warnings[0].includes("not configured"));
  } finally {
    Deno.env.set("PLAY_CLOUD_PROJECT_NUMBER", ENV.PLAY_CLOUD_PROJECT_NUMBER);
  }
});

Deno.test("androidCheck: past the hourly limit it answers 429 before asking Google", async () => {
  reset();
  world.rpcResults.tooMany = true;
  const error = await assertRejects(() => androidCheck(user, token), HttpError);
  assertEquals((error as InstanceType<typeof HttpError>).status, 429);
  assertEquals(world.decodes, 0);
  assertEquals(calls("record_device_check").length, 0);
});

Deno.test("androidCheck: an account in good standing verified today isn't decoded again", async () => {
  reset();
  world.rpcResults.device_check_begin = [{ standing: "ok", verified_at: hoursAgo(1), has_pending: false }];
  assertEquals((await androidCheck(user, token, now)).status, 204);
  assertEquals(world.decodes, 0);
  assertEquals(calls("record_device_check").length, 0);
});

Deno.test("androidCheck: it is decoded when the last check is old, a change waits, or the account is restricted", async () => {
  for (
    const begin of [
      { standing: "ok", verified_at: hoursAgo(25), has_pending: false },
      { standing: "ok", verified_at: null, has_pending: false },
      { standing: "ok", verified_at: hoursAgo(1), has_pending: true },
      { standing: "held", verified_at: hoursAgo(1), has_pending: false },
      { standing: "banned", verified_at: hoursAgo(1), has_pending: false },
    ]
  ) {
    reset();
    world.rpcResults.device_check_begin = [begin];
    await androidCheck(user, token, now);
    assertEquals(world.decodes, 1, JSON.stringify(begin));
  }
});

Deno.test("androidCheck: a refused token is never stored and writes nothing", async () => {
  for (const change of [() => (world.device = []), () => (world.otherHash = true)]) {
    reset();
    change();
    world.rpcResults.record_device_check = "ban";
    const { warnings, errors } = await logged(async () => {
      assertEquals((await androidCheck(user, token)).status, 204);
    });
    assertEquals(calls("record_device_check").length, 0);
    assertEquals(world.writes, []);
    assertEquals(errors, []);
    assertEquals(warnings.length, 1);
  }
});

Deno.test("androidCheck: a refused token of a closed or held account is logged as an error", async () => {
  for (const standing of ["banned", "held"]) {
    reset();
    world.device = [];
    world.rpcResults.device_check_begin = [{ standing, verified_at: null, has_pending: false }];
    const { errors } = await logged(async () => {
      await androidCheck(user, token);
    });
    assertEquals(errors.length, 1);
    assert(errors[0].includes(standing) && errors[0].includes("device"));
  }
});

Deno.test("androidCheck: Google's failures are told apart and never reach the person", async () => {
  reset();
  world.decodeStatus = 400;
  let logs = await logged(async () => {
    assertEquals((await androidCheck(user, token)).status, 204);
  });
  assertEquals([logs.errors.length, logs.warnings.length], [0, 1], "a token Google refuses: our client's fault");
  assertEquals(calls("record_device_check").length, 0);

  for (const status of [403, 429, 500]) {
    reset();
    world.decodeStatus = status;
    logs = await logged(async () => {
      assertEquals((await androidCheck(user, token)).status, 204);
    });
    assertEquals(logs.errors.length, 1, `${status} is ours`);
  }

  reset();
  world.signInStatus = 400;
  logs = await logged(async () => {
    assertEquals((await androidCheck(user, token)).status, 204);
  });
  assertEquals(logs.errors.length, 1);
  assert(logs.errors[0].includes("credentials"));
});

Deno.test("androidCheck: it stores the token for this platform", async () => {
  reset();
  await androidCheck(user, token);
  assertEquals(calls("record_device_check")[0].args, {
    p_user: user,
    p_token: token,
    p_environment: "production",
    p_platform: "android",
  });
});

Deno.test("androidCheck: a closed or held account sets its bit, once", async () => {
  for (
    const [next, bits, written] of [
      ["ban", {}, { bitFirst: true }],
      ["ban", { bitFirst: true }, undefined],
      ["hold", {}, { bitSecond: true }],
      ["hold", { bitSecond: true }, undefined],
    ] as const
  ) {
    reset();
    world.rpcResults.record_device_check = next;
    world.bits = bits;
    await androidCheck(user, token);
    assertEquals(world.writes, written ? [written] : [], `${next} ${JSON.stringify(bits)}`);
    assertEquals(calls("device_flagged").length, 0);
  }
});

Deno.test("androidCheck: an account in good standing is flagged by another account's mark, once", async () => {
  reset();
  world.bits = { bitFirst: true };
  await androidCheck(user, token);
  assertEquals(calls("device_flagged")[0].args, { p_user: user, p_closed: true, p_held: false });

  reset();
  world.bits = { bitSecond: true };
  await androidCheck(user, token);
  assertEquals(calls("device_flagged")[0].args, { p_user: user, p_closed: false, p_held: true });

  reset();
  await androidCheck(user, token);
  assertEquals(calls("device_flagged").length, 0, "no bit, no flag");

  reset();
  world.rpcResults.record_device_check = "none";
  world.bits = { bitFirst: true };
  await androidCheck(user, token);
  assertEquals(calls("device_flagged").length, 0, "already flagged once");
  assertEquals(world.writes, []);
});

Deno.test("androidCheck: a change that waited is written with the new token, and the bits read aren't held against the person", async () => {
  reset();
  world.rpcResults.device_check_take_pending = [{ bit0: false, bit1: null }];
  world.bits = { bitFirst: true };
  await androidCheck(user, token);
  assertEquals(world.writes, [{ bitFirst: false }]);
  assertEquals(calls("device_flagged").length, 0);
  assertEquals(calls("device_check_set_pending").length, 0);
});

Deno.test("androidCheck: what waited covers the other bit, the account's standing decides its own", async () => {
  reset();
  world.rpcResults.record_device_check = "hold";
  world.rpcResults.device_check_take_pending = [{ bit0: false, bit1: false }];
  world.bits = { bitFirst: true };
  await androidCheck(user, token);
  assertEquals(world.writes, [{ bitFirst: false, bitSecond: true }]);

  reset();
  world.rpcResults.record_device_check = "ban";
  world.rpcResults.device_check_take_pending = [{ bit0: false, bit1: null }];
  await androidCheck(user, token);
  assertEquals(world.writes, [{ bitFirst: true }], "a stale clear never overrides the ban");
});

Deno.test("androidCheck: a write that fails puts the waiting change back", async () => {
  reset();
  world.writeStatus = 500;
  world.rpcResults.device_check_take_pending = [{ bit0: false, bit1: null }];
  world.bits = { bitFirst: true };
  const { errors } = await logged(async () => {
    assertEquals((await androidCheck(user, token)).status, 204);
  });
  assertEquals(calls("device_check_set_pending")[0].args, { p_user: user, p_bit0: false, p_bit1: null });
  assert(errors[0].includes("write failed"));
});

Deno.test("androidCheck: a failure to read what waited is logged by its step, and the answer stays a 204", async () => {
  reset();
  world.failRpc = ["device_check_take_pending"];
  world.bits = { bitFirst: true };
  const { errors } = await logged(async () => {
    assertEquals((await androidCheck(user, token)).status, 204);
  });
  assert(errors[0].includes("take pending failed"));
  assertEquals(calls("device_flagged").length, 0);
});

Deno.test("androidCheck: a failure of the flag is logged as such, not as Google's", async () => {
  reset();
  world.bits = { bitFirst: true };
  world.failRpc = ["device_flagged"];
  const { errors } = await logged(async () => {
    assertEquals((await androidCheck(user, token)).status, 204);
  });
  assert(errors[0].includes("flag failed"));
});
