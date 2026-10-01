// db-events handlers under partial failure (FLOW-09): an event that fails halfway is retried (or replayed
// from sophros) with the steps it already did, and no side effect happens twice or gets lost.
//
//   cd supabase/functions && deno test --allow-env --allow-read=. db-events/
//
// No network: fetch is replaced by a small world (PostgREST, Auth admin, APNs, Resend, R2, Rekognition)
// and Stream by a fake client. Everything they're asked is recorded.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { unzipSync } from "npm:fflate@0.8.2";
import { withRenditions } from "../_shared/renditions.ts";

// A throwaway P-256 key for the APNs provider token.
const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
// And a throwaway RSA key for the FCM service account.
const rsa = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"],
);
const rsaPkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", rsa.privateKey));
const rsaPem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...rsaPkcs8))}\n-----END PRIVATE KEY-----`;

const ENV: Record<string, string> = {
  SUPABASE_URL: "http://supabase.test",
  SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
  SUPABASE_SECRET_KEYS: "",
  APNS_KEY_ID: "KEY",
  APNS_TEAM_ID: "TEAM",
  APNS_BUNDLE_ID: "so.drafft.app",
  APNS_PRIVATE_KEY: pem,
  FCM_SERVICE_ACCOUNT: JSON.stringify({
    project_id: "drafft-test",
    client_email: "push@drafft-test.iam.gserviceaccount.com",
    private_key: rsaPem,
  }),
  EMAIL_FROM: "drafft <no-reply@mail.drafft.test>",
  RESEND_API_KEY: "test-resend",
  SUPPORT_INBOX: "team@drafft.so",
  R2_ACCESS_KEY_ID: "r2",
  R2_SECRET_ACCESS_KEY: "r2",
  R2_ACCOUNT_ID: "acct",
  R2_BUCKET: "media",
  AWS_REKOGNITION_ACCESS_KEY_ID: "aws",
  AWS_REKOGNITION_SECRET_ACCESS_KEY: "aws",
  STREAM_API_KEY: "stream",
  STREAM_API_SECRET: "stream",
  MEDIA_PUBLIC_URL: "https://media.test",
  MEDIA_SIGNING_KEY: "test-signing-key",
};
for (const [name, value] of Object.entries(ENV)) Deno.env.set(name, value);
for (const name of ["MAILPIT_URL", "EMAIL_REAL", "MODERATION_MODE"]) Deno.env.delete(name);

// MARK: The world

type Row = Record<string, unknown>;
type Outcome = "ok" | "down" | "network" | "gone";

const world = {
  tables: {} as Record<string, Row[]>,
  users: {} as Record<string, string>,
  rpc: [] as { name: string; args: Row }[],
  rpcResults: {} as Record<string, unknown>,
  failRead: undefined as string | undefined,
  /** RPCs that answer with a server error (each call is still recorded). */
  failRpc: [] as string[],
  pushes: [] as { token: string; collapse: string | null; title?: string; channel?: string }[],
  pushOutcome: {} as Record<string, Outcome>,
  emails: [] as { to: string; key: string | null; replyTo?: string | null; subject?: string; text?: string }[],
  /** The same emails as Resend got them: subject and Reply-To. */
  sent: [] as { to: string; subject: string; replyTo?: string }[],
  emailOutcome: [] as Outcome[],
  rekognition: 0,
  labels: [] as { Name: string; ParentName: string; Confidence: number }[],
  /** DetectFaces: the faces found, or an HTTP status it fails with (an IAM user without the right). */
  faces: [] as { Confidence: number; BoundingBox: { Width: number; Height: number } }[] | number,
  stream: [] as string[],
  streamUsers: [] as Row[],
  /** Stream channels by id: their messages. */
  channels: {} as Record<string, Row[]>,
  /** R2 keys that exist, and the outside deletions (R2, selfies bucket, Stream, Auth), in order. */
  objects: [] as string[],
  selfies: [] as string[],
  erased: [] as string[],
  /** Failures to inject: a Stream call by name (`query`, `delete`, `deleteUsers`, `queryChannels`), R2 deletes,
   * the selfies bucket, the Auth user's deletion. */
  streamFail: {} as Record<string, { status: number; code: number } | undefined>,
  /** What Stream's task says after `deleteUsers`, look after look (then `completed`). */
  taskStatus: [] as string[],
  r2DeleteStatus: 204,
  storageFail: undefined as "list" | "remove" | undefined,
  authDeleteStatus: 200,
  queryPagesOk: 0,
  /** Frozen channels Stream has (chat.sweep), oldest first. */
  frozen: [] as { id: string; created_at: string; updated_at: string }[],
  /** The data-exports bucket: path → bytes, and what was removed. */
  exports: {} as Record<string, Uint8Array>,
  removed: [] as string[],
  /** R2 object sizes by key for reads (a negative one: missing); any other key is 4 bytes. */
  sizes: {} as Record<string, number>,
  /** Stream messages by id, as getMessage reads them. */
  messages: {} as Record<string, Row>,
  /** Renditions asked of the media Worker: `<key> w<width>`. */
  warmed: [] as string[],
};

function reset() {
  world.warmed = [];
  world.tables = {};
  world.users = {};
  world.rpc = [];
  world.rpcResults = {};
  world.failRead = undefined;
  world.failRpc = [];
  world.pushes = [];
  world.pushOutcome = {};
  world.emails = [];
  world.sent = [];
  world.emailOutcome = [];
  world.rekognition = 0;
  world.labels = [];
  world.faces = [];
  world.stream = [];
  world.streamUsers = [];
  world.channels = {};
  world.objects = [];
  world.selfies = [];
  world.erased = [];
  world.streamFail = {};
  world.taskStatus = [];
  world.r2DeleteStatus = 204;
  world.storageFail = undefined;
  world.authDeleteStatus = 200;
  world.queryPagesOk = 0;
  world.frozen = [];
  world.exports = {};
  world.removed = [];
  world.sizes = {};
  world.messages = {};
}

/** PostgREST filters as supabase-js writes them: `col=eq.value`, and `.or(...)` (all rows). */
function select(table: string, params: URLSearchParams): Row[] {
  return (world.tables[table] ?? []).filter((row) => {
    for (const [key, value] of params) {
      if (["select", "order", "or", "limit"].includes(key)) continue;
      if (value.startsWith("eq.") && String(row[key]) !== value.slice(3)) return false;
      if (value.startsWith("in.")) {
        const list = value.slice(4, -1).split(",").map((v) => v.replace(/"/g, ""));
        if (!list.includes(String(row[key]))) return false;
      }
    }
    return true;
  });
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
  const body = request.method === "GET" || request.method === "HEAD"
    ? new Uint8Array()
    : new Uint8Array(await request.arrayBuffer());
  const text = new TextDecoder().decode(body);

  if (url.host === "supabase.test") {
    if (url.pathname.startsWith("/rest/v1/rpc/")) {
      const name = url.pathname.slice("/rest/v1/rpc/".length);
      world.rpc.push({ name, args: text ? JSON.parse(text) : {} });
      if (world.failRpc.includes(name)) return respond({ message: "connection reset" }, 500);
      return respond(world.rpcResults[name] ?? null);
    }
    if (url.pathname.startsWith("/storage/v1/object/sign/data-exports/")) {
      const path = url.pathname.slice("/storage/v1/object/sign/data-exports/".length);
      return respond({ signedURL: `/object/sign/data-exports/${path}?token=signed` });
    }
    if (url.pathname.startsWith("/storage/v1/object/data-exports/") && request.method === "POST") {
      world.exports[decodeURIComponent(url.pathname.slice("/storage/v1/object/data-exports/".length))] = body;
      return respond({ Key: url.pathname });
    }
    if (url.pathname === "/storage/v1/object/list/data-exports") {
      const { prefix, search } = JSON.parse(text) as { prefix: string; search?: string };
      return respond(
        Object.keys(world.exports).filter((path) => path.startsWith(`${prefix}/${search ?? ""}`))
          .map((path) => ({ name: path.slice(prefix.length + 1) })),
      );
    }
    if (url.pathname === "/storage/v1/object/data-exports" && request.method === "DELETE") {
      const prefixes = (JSON.parse(text) as { prefixes: string[] }).prefixes;
      world.removed.push(...prefixes);
      for (const path of prefixes) delete world.exports[path];
      return respond([]);
    }
    if (url.pathname.startsWith("/auth/v1/admin/users/") && request.method === "DELETE") {
      if (world.authDeleteStatus !== 200) {
        return respond({ code: world.authDeleteStatus, msg: "no" }, world.authDeleteStatus);
      }
      world.erased.push(`auth ${url.pathname.split("/").pop()}`);
      return respond({});
    }
    if (url.pathname === "/storage/v1/object/list/verification-selfies") {
      if (world.storageFail === "list") return respond({ statusCode: "500", error: "boom", message: "boom" }, 500);
      return respond(world.selfies.map((name) => ({ name })));
    }
    if (url.pathname === "/storage/v1/object/verification-selfies" && request.method === "DELETE") {
      if (world.storageFail === "remove") return respond({ statusCode: "500", error: "boom", message: "boom" }, 500);
      world.erased.push(`selfies ${(JSON.parse(text) as { prefixes: string[] }).prefixes.join(" ")}`);
      world.selfies = [];
      return respond([]);
    }
    if (url.pathname.startsWith("/auth/v1/admin/users/")) {
      const id = url.pathname.split("/").pop()!;
      const email = world.users[id];
      return email ? respond({ id, email }) : respond({ code: 404, msg: "User not found" }, 404);
    }
    const table = url.pathname.slice("/rest/v1/".length);
    if (world.failRead === table) return respond({ message: "connection reset" }, 500);
    if (request.method === "GET") {
      const rows = select(table, url.searchParams);
      const single = (request.headers.get("accept") ?? "").includes("vnd.pgrst.object");
      if (single) return rows[0] ? respond(rows[0]) : respond({ message: "no rows" }, 406);
      return respond(rows);
    }
    if (request.method === "PATCH") {
      for (const row of select(table, url.searchParams)) Object.assign(row, JSON.parse(text));
      return respond(undefined, 204);
    }
    if (request.method === "DELETE" && table === "push_tokens") {
      const gone = new Set(select(table, url.searchParams));
      world.tables[table] = world.tables[table].filter((row) => !gone.has(row));
      return respond(undefined, 204);
    }
    return respond(undefined, 204);
  }

  if (url.host.endsWith("push.apple.com")) {
    const token = url.pathname.split("/").pop()!;
    const outcome = world.pushOutcome[token] ?? "ok";
    if (outcome === "network") throw new TypeError("error sending request: connection refused");
    if (outcome === "down") return respond({ reason: "ServiceUnavailable" }, 503);
    world.pushes.push({
      token,
      collapse: request.headers.get("apns-collapse-id"),
      title: JSON.parse(text).aps?.alert?.title,
    });
    return respond(undefined, 200);
  }

  if (url.host === "oauth2.googleapis.com") {
    return respond({ access_token: "fcm-access", expires_in: 3600, token_type: "Bearer" });
  }

  if (url.host === "fcm.googleapis.com") {
    const message = JSON.parse(text).message;
    const outcome = world.pushOutcome[message.token] ?? "ok";
    if (outcome === "network") throw new TypeError("error sending request: connection refused");
    if (outcome === "down") return respond({ error: { code: 503, status: "UNAVAILABLE" } }, 503);
    if (outcome === "gone") {
      return respond({
        error: { code: 404, status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] },
      }, 404);
    }
    world.pushes.push({
      token: message.token,
      collapse: message.android?.collapse_key ?? null,
      title: message.notification?.title,
      channel: message.android?.notification?.channel_id,
    });
    return respond({ name: `projects/drafft-test/messages/${world.pushes.length}` });
  }

  if (url.host === "api.resend.com") {
    const outcome = world.emailOutcome.shift() ?? "ok";
    if (outcome === "network") throw new TypeError("error sending request: connection reset");
    if (outcome === "down") return respond({ message: "service unavailable" }, 503);
    const body = JSON.parse(text) as { to: string[]; reply_to?: string; subject: string; text: string };
    world.emails.push({
      to: body.to[0],
      key: request.headers.get("idempotency-key"),
      replyTo: body.reply_to ?? null,
      subject: body.subject,
      text: body.text,
    });
    world.sent.push({ to: body.to[0], subject: body.subject, replyTo: body.reply_to });
    return respond({ id: crypto.randomUUID() });
  }

  if (url.host.endsWith("r2.cloudflarestorage.com")) {
    if (url.searchParams.get("list-type") === "2") {
      const prefix = url.searchParams.get("prefix") ?? "";
      const keys = world.objects.filter((k) => k.startsWith(prefix)).map((k) => `<Key>${k}</Key>`).join("");
      return new Response(`<ListBucketResult>${keys}</ListBucketResult>`, { status: 200 });
    }
    if (request.method === "DELETE") {
      if (world.r2DeleteStatus !== 204) return new Response(null, { status: world.r2DeleteStatus });
      const deleted = decodeURIComponent(url.pathname.split("/").slice(2).join("/"));
      world.erased.push(`r2 ${deleted}`);
      world.objects = world.objects.filter((k) => k !== deleted);
      return new Response(null, { status: 204 });
    }
    const key = decodeURIComponent(url.pathname.split("/").slice(2).join("/"));
    const size = world.sizes[key] ?? 4;
    if (size < 0) return new Response(null, { status: 404 });
    if (request.method === "HEAD") return new Response(null, { status: 200, headers: { "content-length": `${size}` } });
    return new Response(new Uint8Array(size).fill(7), { status: 200 });
  }

  if (url.host === "media.test") {
    world.warmed.push(`${url.pathname.slice(1)} w${url.searchParams.get("w")}`);
    return new Response("webp", { status: 200 });
  }

  if (url.host.startsWith("rekognition.")) {
    if (request.headers.get("x-amz-target") === "RekognitionService.DetectFaces") {
      return typeof world.faces === "number"
        ? new Response("AccessDeniedException", { status: world.faces })
        : respond({ FaceDetails: world.faces });
    }
    world.rekognition++;
    return respond({ ModerationLabels: world.labels });
  }

  throw new Error(`unexpected fetch in a test: ${request.method} ${url}`);
};

// Stream: channels and messages by id, like the real thing (a duplicate id is refused). Errors have Stream's
// shape: an HTTP status and Stream's own code (16: it doesn't have it).
const messages = new Set<string>();
function streamError(what: string, status: number, code: number) {
  return Promise.reject(Object.assign(new Error(`StreamChat error code ${code}: ${what}`), { status, code }));
}
function injected(call: string) {
  const fail = world.streamFail[call];
  return fail ? streamError(`${call} failed`, fail.status, fail.code) : null;
}
const fakeStream = {
  channel: (_type: string, id: string) => ({
    create: () => {
      world.stream.push(`create ${id}`);
      return Promise.resolve({});
    },
    delete: (options?: { hard_delete?: boolean }) => {
      const fail = injected("delete");
      if (fail) return fail;
      if (!world.channels[id]) return streamError(`channel messaging:${id} does not exist`, 404, 16);
      delete world.channels[id];
      world.erased.push(`stream channel ${id}${options?.hard_delete ? " hard" : ""}`);
      return Promise.resolve({});
    },
    // Oldest first, `limit` of them before `id_lt`, like the real thing. On a channel Stream doesn't have, a
    // query is a get-or-create, and without a creator the creation is refused (400), never a 404.
    query: (options: { messages?: { limit?: number; id_lt?: string } }) => {
      // A failure injected for `query` hits the pages after the first `queryPagesOk`.
      if (world.queryPagesOk-- <= 0) {
        const fail = injected("query");
        if (fail) return fail;
      }
      const all = world.channels[id];
      if (!all) return streamError("either data.created_by or data.created_by_id must be provided", 400, 4);
      const end = options.messages?.id_lt ? all.findIndex((m) => m.id === options.messages?.id_lt) : all.length;
      const limit = options.messages?.limit ?? 25;
      return Promise.resolve({ messages: all.slice(Math.max(0, end - limit), end) });
    },
    removeMembers: (ids: string[]) => {
      const fail = injected("removeMembers");
      if (fail) return fail;
      if (!world.channels[id]) return streamError(`channel messaging:${id} does not exist`, 404, 16);
      world.stream.push(`leave ${id} ${ids.join(" ")}`);
      return Promise.resolve({});
    },
    updatePartial: (update: { set?: Row }) => {
      world.stream.push(`update ${id} ${JSON.stringify(update.set)}`);
      return Promise.resolve({});
    },
    sendMessage: (m: { id: string }, options?: { skip_push?: boolean }) => {
      if (messages.has(m.id)) return Promise.reject(new Error(`StreamChat error: message ${m.id} already exists`));
      messages.add(m.id);
      // Server messages come with db-events' own push, never Stream's.
      if (!options?.skip_push) return Promise.reject(new Error(`message ${m.id} sent with Stream's push`));
      world.stream.push(`message ${m.id}`);
      return Promise.resolve({});
    },
  }),
  upsertUsers: (users: Row[]) => {
    world.streamUsers.push(...users);
    return Promise.resolve({});
  },
  upsertUser: () => Promise.resolve({}),
  banUser: () => Promise.resolve({}),
  unbanUser: () => Promise.resolve({}),
  setPushPreferences: () => Promise.resolve({}),
  deleteUsers: (ids: string[], options: Row) => {
    const fail = injected("deleteUsers");
    if (fail) return fail;
    world.erased.push(`stream user ${ids.join(" ")} ${options.user}`);
    return Promise.resolve({ task_id: "t" });
  },
  getTask: (id: string) => {
    world.stream.push(`task ${id}`);
    const status = world.taskStatus.shift() ?? "completed";
    return Promise.resolve({ task_id: id, status, ...(status === "failed" ? { error: { description: "boom" } } : {}) });
  },
  // Search: never creates anything; by id, or frozen channels created after a date, oldest first.
  queryChannelsRequest: (filter: Row, _sort: unknown, options: { limit?: number }) => {
    const fail = injected("queryChannels");
    if (fail) return fail;
    const id = (filter.id as { $eq?: string } | undefined)?.$eq;
    if (id) return Promise.resolve(world.channels[id] ? [{ channel: { id } }] : []);
    const after = (filter.created_at as { $gt: string }).$gt;
    return Promise.resolve(
      world.frozen.filter((c) => c.created_at > after).slice(0, options.limit ?? 30).map((channel) => ({ channel })),
    );
  },
  getMessage: (id: string) =>
    world.messages[id]
      ? Promise.resolve({ message: world.messages[id] })
      : world.streamFail.getMessage
      ? Promise.reject(Object.assign(new Error("StreamChat error code -1: boom"), world.streamFail.getMessage))
      : Promise.reject(Object.assign(new Error(`StreamChat error code 16: message ${id} not found`), {
        status: 404,
        code: 16,
      })),
};

const { useStreamClientForTests } = await import("../_shared/stream.ts");
useStreamClientForTests(fakeStream);
const { chatMediaKeys, timing } = await import("../_shared/erase.ts");
const { renderDecision } = await import("../_shared/notices.ts");
timing.sleep = () => Promise.resolve();
const { runEvent } = await import("./handlers.ts");

// MARK: Helpers

const ana = "11111111-1111-4111-8111-111111111111";
const bo = "22222222-2222-4222-8222-222222222222";
const match = "33333333-3333-4333-8333-333333333333";
const media = "44444444-4444-4444-8444-444444444444";

function steps(id: number): string[] {
  return world.rpc.filter((c) => c.name === "outbox_step_done" && c.args.p_id === id).map((c) => String(c.args.p_step));
}
function calls(name: string) {
  return world.rpc.filter((c) => c.name === name);
}
const inAnHour = () => new Date(Date.now() + 3600_000).toISOString();

function people() {
  world.tables.profiles = [
    { id: ana, name: "Ana", language: "fr", notify_matches: true, notify_messages: true, notify_likes: true },
    { id: bo, name: "Bo", language: "en", notify_matches: true, notify_messages: true, notify_likes: true },
  ];
  world.tables.push_tokens = [
    { user_id: ana, token: "ana-phone", environment: "sandbox" },
    { user_id: bo, token: "bo-phone", environment: "sandbox" },
  ];
  world.users = { [ana]: "ana@drafft.so", [bo]: "bo@drafft.so" };
}

// MARK: Tests

Deno.test("match.created: a push that fails is retried alone, nothing else is sent twice", async () => {
  reset();
  people();
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo, ended_at: null }];
  world.tables.swipes = [{ swiper: ana, target: bo, action: "like", opener: { kind: "text", text: "Run?" } }];
  world.pushOutcome["bo-phone"] = "network";
  const event = {
    id: 1,
    event: "match.created",
    payload: { matchId: match, userA: ana, userB: bo },
    pushUntil: inAnHour(),
  };

  await assertRejects(() => runEvent(event));
  const failed = calls("outbox_failed")[0].args;
  assertEquals([failed.p_provider, failed.p_transient], ["apns", true], "APNs down is transient, and named");
  assert((failed.p_providers as string[]).includes("stream"), "Stream worked: its circuit hears it");
  assertEquals(calls("ack_event").length, 0, "not acked");
  assertEquals(steps(1), [`opener-${ana}`, "push-a"]);
  assertEquals(world.pushes.map((p) => p.token), ["ana-phone"]);

  // The retry, with the steps done.
  world.pushOutcome["bo-phone"] = "ok";
  world.rpc = [];
  await runEvent({ ...event, steps: [`opener-${ana}`, "push-a"] });
  assertEquals(world.pushes.map((p) => p.token), ["ana-phone", "bo-phone"], "Ana isn't told twice");
  assertEquals(world.stream.filter((s) => s.startsWith("message")).length, 1, "the opener is posted once");
  assertEquals(world.pushes[1].collapse, `match-${match}`);
  assertEquals(calls("ack_event")[0].args.p_providers, ["stream", "apns"]);
});

Deno.test("match.created: past its push freshness, the channel still opens but nobody is pushed", async () => {
  reset();
  people();
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo, ended_at: null }];
  world.tables.swipes = [];
  await runEvent({
    id: 2,
    event: "match.created",
    payload: { matchId: match, userA: ana, userB: bo },
    pushUntil: new Date(Date.now() - 1000).toISOString(),
  });
  assertEquals(world.stream, [`create ${match}`]);
  assertEquals(world.pushes, []);
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("pushToUser: one device down and one served is not a failure (no second push on retry)", async () => {
  reset();
  people();
  world.tables.push_tokens.push({ user_id: bo, token: "bo-ipad", environment: "sandbox" });
  world.pushOutcome["bo-ipad"] = "down";
  await runEvent({ id: 3, event: "like.received", payload: { from: ana, to: bo, superLike: false } });
  assertEquals(world.pushes.map((p) => p.token), ["bo-phone"]);
  assertEquals(calls("ack_event").length, 1);
  assertEquals(steps(3), ["push"]);
});

Deno.test("pushToUser: an Android phone gets it through FCM, on the channel of its kind", async () => {
  reset();
  people();
  world.tables.push_tokens.push({ user_id: bo, token: "bo-android", environment: "production", platform: "android" });
  await runEvent({ id: 30, event: "like.received", payload: { from: ana, to: bo, superLike: false } });
  assertEquals(world.pushes.map((p) => [p.token, p.channel ?? null]), [["bo-phone", null], ["bo-android", "likes"]]);
  assertEquals(world.pushes[1].collapse, "likes");
  assertEquals(calls("ack_event")[0].args.p_providers, ["apns", "fcm"]);
});

Deno.test("pushToUser: an uninstalled Android app's token is removed, not retried", async () => {
  reset();
  people();
  world.tables.push_tokens = [{ user_id: bo, token: "bo-android", environment: "production", platform: "android" }];
  world.pushOutcome["bo-android"] = "gone";
  await runEvent({ id: 31, event: "like.received", payload: { from: ana, to: bo, superLike: false } });
  assertEquals(world.tables.push_tokens, []);
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("pushToUser: FCM down for every device of a person is a transient failure named fcm", async () => {
  reset();
  people();
  world.tables.push_tokens = [{ user_id: bo, token: "bo-android", environment: "production", platform: "android" }];
  world.pushOutcome["bo-android"] = "down";
  await assertRejects(() =>
    runEvent({ id: 32, event: "like.received", payload: { from: ana, to: bo, superLike: false } })
  );
  const failed = calls("outbox_failed")[0].args;
  assertEquals([failed.p_provider, failed.p_transient], ["fcm", true]);
});

Deno.test("media.created: verdict and flag at once; a failed refusal push is resent without a second verdict", async () => {
  reset();
  people();
  const key = `u/${ana}/photos/1.jpg`;
  world.tables.profile_media = [{ id: media, user_id: ana, status: "pending", key }];
  world.labels = [{ Name: "Explicit Nudity", ParentName: "", Confidence: 99 }];
  world.rpcResults.apply_media_verdict = true;
  world.pushOutcome["ana-phone"] = "down";
  const event = { id: 4, event: "media.created", payload: { mediaId: media, userId: ana, key }, pushUntil: inAnHour() };

  await assertRejects(() => runEvent(event));
  assertEquals(calls("apply_media_verdict").length, 1);
  assertEquals(calls("apply_media_verdict")[0].args.p_verdict, "rejected");
  assertEquals(steps(4), ["verdict=rejected"]);
  assertEquals(calls("outbox_failed")[0].args.p_provider, "apns");

  // The database applied it: the photo is refused now.
  world.tables.profile_media[0].status = "rejected";
  world.pushOutcome["ana-phone"] = "ok";
  world.rpc = [];
  await runEvent({ ...event, steps: ["verdict=rejected"] });
  assertEquals(world.rekognition, 1, "not judged twice");
  assertEquals(calls("apply_media_verdict").length, 0, "no second verdict or flag");
  assertEquals(world.pushes.map((p) => p.collapse), [`photo-${media}`], "the refusal push goes out");
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("media.created: the face goes with the verdict; a face check that fails leaves it unknown", async () => {
  reset();
  people();
  const key = `u/${ana}/photos/3.jpg`;
  world.tables.profile_media = [{ id: media, user_id: ana, status: "pending", key }];
  world.rpcResults.apply_media_verdict = true;
  world.faces = [{ Confidence: 99, BoundingBox: { Width: 0.3, Height: 0.4 } }];
  await runEvent({ id: 7, event: "media.created", payload: { mediaId: media, userId: ana, key } });
  assertEquals(calls("apply_media_verdict")[0].args.p_verdict, "approved");
  assertEquals(calls("apply_media_verdict")[0].args.p_face, true);

  world.rpc = [];
  world.faces = 403;
  await runEvent({ id: 8, event: "media.created", payload: { mediaId: media, userId: ana, key } });
  assertEquals(calls("apply_media_verdict")[0].args.p_verdict, "approved", "the verdict still applies");
  assertEquals(calls("apply_media_verdict")[0].args.p_face, null);
});

Deno.test("media.created: a video's poster is judged, its face never asked", async () => {
  reset();
  people();
  const key = `u/${ana}/videos/1.mp4`;
  world.tables.profile_media = [{ id: media, user_id: ana, status: "pending", key }];
  world.rpcResults.apply_media_verdict = true;
  world.faces = 500;
  await runEvent({
    id: 9,
    event: "media.created",
    payload: { mediaId: media, userId: ana, key, posterKey: `u/${ana}/posters/1.jpg` },
  });
  assertEquals(calls("apply_media_verdict")[0].args.p_face, null);
});

Deno.test("media.created: decided by a person meanwhile, the automatic verdict stays out", async () => {
  reset();
  people();
  const key = `u/${ana}/photos/2.jpg`;
  world.tables.profile_media = [{ id: media, user_id: ana, status: "pending", key }];
  world.rpcResults.apply_media_verdict = false;
  world.labels = [{ Name: "Explicit Nudity", ParentName: "", Confidence: 99 }];
  await runEvent({ id: 5, event: "media.created", payload: { mediaId: media, userId: ana, key } });
  assertEquals(world.pushes, [], "no refusal push for a decision that didn't apply");
  assertEquals(steps(5), []);
});

Deno.test("media.approved_on_review: a failed read is retried, never acked as nothing to do", async () => {
  reset();
  people();
  world.failRead = "profile_media";
  await assertRejects(() =>
    runEvent({ id: 6, event: "media.approved_on_review", payload: { mediaId: media, userId: ana } })
  );
  assertEquals(calls("ack_event").length, 0);
  assertEquals(calls("outbox_failed")[0].args.p_provider, null, "not a provider's fault");
  assertEquals(world.emails, []);
});

Deno.test("support.created: the team copy fails, the retry sends it alone", async () => {
  reset();
  world.rpcResults.support_request = [{
    reference: "DR-ABC123",
    user_id: null,
    email: "lea@drafft.so",
    language: "fr",
    topic: "Help",
    message: "Stuck",
    context: {},
  }];
  world.emailOutcome = ["ok", "down"];
  const event = { id: 7, event: "support.created", payload: { id: 9 } };
  await assertRejects(() => runEvent(event));
  const failed = calls("outbox_failed")[0].args;
  assertEquals([failed.p_provider, failed.p_transient], ["resend", true]);
  assertEquals(steps(7), ["email"]);

  world.rpc = [];
  await runEvent({ ...event, steps: ["email"] });
  assertEquals(
    world.emails.map((e) => e.to),
    ["lea@drafft.so", "team@drafft.so"],
    "the person gets one acknowledgement",
  );
  assertEquals(world.emails[1].key, "support-team-DR-ABC123");
});

Deno.test("support emails carry the reference in the subject and Reply-To the support address", async () => {
  reset();
  world.rpcResults.support_request = [{
    reference: "DR-ABC123",
    user_id: null,
    email: "lea@drafft.so",
    language: "fr",
    topic: "Help",
    message: "Stuck",
    context: {},
  }];
  Deno.env.set("SUPPORT_ADDRESS", "support@drafft.so");
  try {
    await runEvent({ id: 8, event: "support.created", payload: { id: 9 } });
    world.rpcResults.support_reply = [{
      reference: "DR-ABC123",
      email: "lea@drafft.so",
      language: "fr",
      topic: "Help",
      message: "Stuck",
      body: "Try again?",
      author: "sup@drafft.so",
      sent_at: null,
      direction: "out",
    }];
    await runEvent({ id: 9, event: "support.reply", payload: { id: 12 } });
  } finally {
    Deno.env.delete("SUPPORT_ADDRESS");
  }
  assertEquals(world.sent, [
    { to: "lea@drafft.so", subject: "On a bien reçu ton message [DR-ABC123]", replyTo: "support@drafft.so" },
    { to: "team@drafft.so", subject: "[support] DR-ABC123 Help", replyTo: "lea@drafft.so" },
    { to: "lea@drafft.so", subject: "Re: Help [DR-ABC123]", replyTo: "support@drafft.so" },
  ]);

  // Before the support address is set up, replies still reach the team's mailbox.
  world.sent = [];
  await runEvent({ id: 10, event: "support.reply", payload: { id: 12 } });
  assertEquals(world.sent[0].replyTo, "team@drafft.so");
});

Deno.test("support.reply: every failure is recorded on the message, never left sending", async () => {
  const reply = {
    reference: "DR-ABC123",
    email: "lea@drafft.so",
    language: "fr",
    topic: "Help",
    message: "Stuck",
    body: "Try again?",
    author: "sup@drafft.so",
    sent_at: null,
    direction: "out",
  };
  const failure = async (setup: () => void) => {
    reset();
    world.rpcResults.support_reply = [reply];
    setup();
    await assertRejects(() => runEvent({ id: 14, event: "support.reply", payload: { id: 15 } }));
    assertEquals(calls("ack_event").length, 0, "retried");
    return calls("support_reply_sent").map((c) => [c.args.p_id, typeof c.args.p_error]);
  };

  // The reply can't be read.
  assertEquals(await failure(() => world.failRpc.push("support_reply")), [[15, "string"]]);
  assert(String(calls("support_reply_sent")[0].args.p_error).includes("support reply"), "says what failed");
  // Resend refuses it.
  assertEquals(await failure(() => world.emailOutcome.push("down")), [[15, "string"]]);
  // Sent, but not recorded as sent: the retry's email has the same idempotency key.
  assertEquals(await failure(() => world.failRpc.push("support_reply_sent")), [[15, "undefined"], [15, "string"]]);
  assertEquals(world.emails.map((e) => e.key), ["support-reply-15"]);
  // Nothing can be written: the handler's own error still reaches the outbox, which marks the message when it
  // gives up (support_reply_given_up).
  reset();
  world.failRpc.push("support_reply", "support_reply_sent");
  await assertRejects(() => runEvent({ id: 15, event: "support.reply", payload: { id: 15 } }), Error, "support reply");
  assertEquals(calls("outbox_failed").length, 1);
});

Deno.test("support.received: a member's email, filed and reopened, is copied to the team once", async () => {
  reset();
  world.rpcResults.support_reply = [{
    reference: "DR-ABC123",
    email: "lea@drafft.so",
    language: "fr",
    topic: "Help",
    message: "Stuck",
    body: "Still stuck",
    author: "lea@drafft.so",
    sent_at: "2026-09-30T10:00:00Z",
    direction: "in",
  }];
  const event = { id: 11, event: "support.received", payload: { id: 13 } };
  await runEvent(event);
  assertEquals(world.sent, [
    { to: "team@drafft.so", subject: "[support] DR-ABC123 Help: new message", replyTo: "lea@drafft.so" },
  ]);
  assertEquals(world.emails[0].key, "support-received-13");
  assertEquals(steps(11), ["team-email"]);
  await runEvent({ ...event, steps: ["team-email"] });
  assertEquals(world.sent.length, 1, "a replay sends nothing");
});

Deno.test("support: a member's message is never sent back to them, nor a team one copied as received", async () => {
  reset();
  const message = {
    reference: "DR-ABC123",
    email: "lea@drafft.so",
    language: "fr",
    topic: "Help",
    message: "Stuck",
    body: "Still stuck",
    author: "lea@drafft.so",
    sent_at: null,
  };
  world.rpcResults.support_reply = [{ ...message, direction: "in" }];
  await runEvent({ id: 12, event: "support.reply", payload: { id: 14 } });
  assertEquals([world.sent, calls("support_reply_sent")], [[], []]);
  world.rpcResults.support_reply = [{ ...message, direction: "out" }];
  await runEvent({ id: 13, event: "support.received", payload: { id: 14 } });
  assertEquals(world.sent, []);
});

Deno.test("support.created: an email whose sender wasn't verified gets no acknowledgement; the team still does", async () => {
  reset();
  world.rpcResults.support_request = [{
    reference: "DR-NEW234",
    user_id: null,
    email: "someone@else.fr",
    language: "en",
    topic: "Message by email",
    message: "Hello",
    context: { source: "email", verified: false },
  }];
  await runEvent({ id: 14, event: "support.created", payload: { id: 15 } });
  assertEquals(world.sent.map((e) => e.to), ["team@drafft.so"]);
});

Deno.test("account.moderation: a replay after the email does not email again", async () => {
  reset();
  people();
  (world.tables.profiles[0] as Row).moderation = null;
  await runEvent({
    id: 8,
    event: "account.moderation",
    payload: { userId: ana, previous: "review" },
    steps: ["email"],
  });
  assertEquals(world.emails, []);
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("account.moderation: news the person waits for is pushed, a new restriction never", async () => {
  const pushed = async (state: string | null, previous: string | null, selfie = false) => {
    reset();
    people();
    (world.tables.profiles[0] as Row).moderation = state;
    world.rpcResults.review_was_selfie = selfie;
    await runEvent({ id: 12, event: "account.moderation", payload: { userId: ana, state, previous } });
    return world.pushes.length > 0;
  };
  assertEquals(await pushed(null, "review", true), true, "selfie approved");
  assertEquals(await pushed(null, "banned"), true, "reopened");
  assertEquals(await pushed("selfie", null), true, "selfie asked");
  assertEquals(await pushed("selfie", "review", true), true, "selfie asked again");
  assertEquals(await pushed("review", null), false, "under review");
  assertEquals(await pushed("review", "selfie"), false, "selfie sent");
  assertEquals(await pushed("banned", "review"), false, "closed");
});

Deno.test("account.moderation: no push once the state has moved on", async () => {
  reset();
  people();
  (world.tables.profiles[0] as Row).moderation = "banned";
  await runEvent({ id: 13, event: "account.moderation", payload: { userId: ana, state: null, previous: "review" } });
  assertEquals(world.pushes, []);
});

Deno.test("session.accepted: no push about a session already past", async () => {
  reset();
  people();
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo, ended_at: null }];
  world.tables.sessions = [{
    id: "s1",
    sport_id: "run",
    title: null,
    options: [new Date(Date.now() - 7200_000).toISOString()],
    chosen_at: new Date(Date.now() - 7200_000).toISOString(),
  }];
  await runEvent({
    id: 9,
    event: "session.accepted",
    payload: { sessionId: "s1", matchId: match, proposerId: ana, actorId: bo },
    pushUntil: inAnHour(),
  });
  assertEquals(world.stream.filter((s) => s.startsWith("message")), ["message session-s1-accepted"]);
  assertEquals(world.pushes, []);
});

Deno.test("an unknown event is acked", async () => {
  reset();
  await runEvent({ id: 10, event: "nothing.here", payload: {} });
  assertEquals(calls("ack_event")[0].args, { p_id: 10, p_providers: [] });
});

Deno.test("stream.user: Stream's user carries the app language and the previews setting for message pushes", async () => {
  reset();
  people();
  world.tables.profiles[0].notify_message_previews = false;
  world.tables.profiles[1].notify_message_previews = true;
  await runEvent({ id: 90, event: "stream.user", payload: { userId: ana } });
  await runEvent({ id: 91, event: "stream.user", payload: { userId: bo } });
  assertEquals(world.streamUsers, [
    {
      id: ana,
      name: "Ana",
      language: "fr",
      drafft_push: { message: "Nouveau message.", someone: "Quelqu'un", previews: false },
    },
    {
      id: bo,
      name: "Bo",
      language: "en",
      drafft_push: { message: "New message.", someone: "Someone", previews: true },
    },
  ]);
  assertEquals(calls("ack_event").length, 2);
});

Deno.test("stream.user: an account gone since is acked without touching Stream", async () => {
  reset();
  people();
  await runEvent({ id: 92, event: "stream.user", payload: { userId: match } });
  assertEquals(world.streamUsers, []);
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("session.reminder: pushed while the session holds, never once it's cancelled", async () => {
  reset();
  people();
  const at = new Date(Date.now() + 3000_000).toISOString();
  world.tables.profiles[1].notify_session_hour_before = true;
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo, ended_at: null }];
  world.tables.sessions = [{
    id: "s1",
    match_id: match,
    status: "accepted",
    sport_id: "run",
    title: "",
    chosen_at: at,
  }];
  const payload = { sessionId: "s1", matchId: match, to: bo, kind: "hour", at, timezone: "Europe/Paris" };
  await runEvent({ id: 11, event: "session.reminder", payload, pushUntil: inAnHour() });
  assertEquals(world.pushes.map((p) => p.collapse), ["session-reminder-s1-hour"]);

  reset();
  people();
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo, ended_at: null }];
  world.tables.sessions = [{
    id: "s1",
    match_id: match,
    status: "cancelled",
    sport_id: "run",
    title: "",
    chosen_at: at,
  }];
  await runEvent({ id: 12, event: "session.reminder", payload, pushUntil: inAnHour() });
  assertEquals(world.pushes, []);
  assertEquals(calls("ack_event").length, 1);
});

// MARK: Retention purges (20260930000201)

const cy = "55555555-5555-4555-8555-555555555555";
const match2 = "66666666-6666-4666-8666-666666666666";

/** A chat of `n` messages: Ana's photo in the second, Bo's video and its poster in the last. */
function chat(n: number): Row[] {
  return Array.from({ length: n }, (_, i) => ({
    id: `m${i}`,
    user: { id: i === n - 1 ? bo : ana },
    attachments: i === 1
      ? [{ type: "drafft_media", key: `u/${ana}/chat/p${i}.jpg` }]
      : i === n - 1
      ? [{ type: "drafft_media", key: `u/${bo}/chat/v${i}.mp4`, poster_key: `u/${bo}/chat/v${i}.jpg` }]
      : [],
  }));
}

Deno.test("chatMediaKeys: only the sender's own chat objects", () => {
  assertEquals(
    chatMediaKeys([
      { id: "a", user: { id: ana }, attachments: [{ type: "drafft_media", key: `u/${ana}/chat/a.jpg` }] },
      // Someone else's object, a profile photo, a traversal, a key that isn't text, another kind of attachment.
      { id: "b", user: { id: ana }, attachments: [{ type: "drafft_media", key: `u/${bo}/chat/b.jpg` }] },
      { id: "c", user: { id: ana }, attachments: [{ type: "drafft_media", key: `u/${ana}/photos/c.jpg` }] },
      { id: "d", user: { id: ana }, attachments: [{ type: "drafft_media", key: `u/${ana}/chat/../photos/d.jpg` }] },
      { id: "e", user: { id: ana }, attachments: [{ type: "drafft_media", key: 42 }] },
      { id: "f", user: { id: ana }, attachments: [{ type: "image", key: `u/${ana}/chat/f.jpg` }] },
      // No sender, or one in capitals (ids are lowercase): the video's poster comes with it.
      { id: "g", attachments: [{ type: "drafft_media", key: `u/${ana}/chat/g.jpg` }] },
      {
        id: "h",
        user: { id: bo.toUpperCase() },
        attachments: [{ type: "drafft_media", key: `u/${bo}/chat/h.mp4`, poster_key: `u/${bo}/chat/h.jpg` }],
      },
    ]),
    [`u/${ana}/chat/a.jpg`, `u/${bo}/chat/h.mp4`, `u/${bo}/chat/h.jpg`],
  );
});

Deno.test("chat.erase: every page's media, each sender's own, then the channel, for good", async () => {
  reset();
  world.rpcResults.chat_erase_due = true;
  world.channels[match] = chat(650);
  // Ana's message pointing at Bo's photo: attachments are the app's, never trusted.
  world.channels[match][5].attachments = [{ type: "drafft_media", key: `u/${bo}/photos/profile.jpg` }];
  await runEvent({ id: 30, event: "chat.erase", payload: { matchId: match } });
  // Media first, with the renditions the Worker kept (in any order: 20 at a time), the channel last.
  const media = [`u/${ana}/chat/p1.jpg`, `u/${bo}/chat/v649.jpg`, `u/${bo}/chat/v649.mp4`]
    .flatMap(withRenditions).map((k) => `r2 ${k}`).sort();
  assertEquals(world.erased.slice(0, media.length).sort(), media);
  assertEquals(world.erased.slice(media.length), [`stream channel ${match} hard`]);
  assertEquals(steps(30), ["chat"]);
  assertEquals(calls("chat_erased")[0].args, { p_match: match });
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("chat.erase: exactly two full pages end on an empty third", async () => {
  reset();
  world.rpcResults.chat_erase_due = true;
  world.channels[match] = chat(600);
  await runEvent({ id: 31, event: "chat.erase", payload: { matchId: match } });
  assertEquals(world.erased.at(-1), `stream channel ${match} hard`);
  // Three objects (two of them photos, with their renditions), then the channel.
  assertEquals(world.erased.length, 1 + 2 * withRenditions("x.jpg").length + 1);
});

Deno.test("chat.erase: a channel Stream doesn't have is done without creating it; one not due is left alone", async () => {
  reset();
  world.rpcResults.chat_erase_due = true;
  await runEvent({ id: 32, event: "chat.erase", payload: { matchId: match } });
  assertEquals(world.erased, []);
  assertEquals(world.stream, [], "no query, no create");
  assertEquals(calls("chat_erased").length, 1, "nothing left to track");
  assertEquals(calls("ack_event").length, 1);

  reset();
  world.rpcResults.chat_erase_due = false;
  world.channels[match] = chat(3);
  await runEvent({ id: 33, event: "chat.erase", payload: { matchId: match } });
  assertEquals(world.erased, []);
  assertEquals(calls("chat_erased").length, 0);
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("chat.erase: an R2 failure keeps the channel and the tracking, and the event fails", async () => {
  reset();
  world.rpcResults.chat_erase_due = true;
  world.channels[match] = chat(3);
  world.r2DeleteStatus = 403;
  await assertRejects(() => runEvent({ id: 34, event: "chat.erase", payload: { matchId: match } }));
  assert(world.channels[match], "the channel is still there");
  assertEquals(steps(34), []);
  assertEquals(calls("chat_erased").length, 0);
  assertEquals(calls("outbox_failed")[0].args.p_provider, "r2");
  assertEquals(calls("ack_event").length, 0);
});

Deno.test("chat.erase: Stream failing on the second page deletes nothing", async () => {
  reset();
  world.rpcResults.chat_erase_due = true;
  world.channels[match] = chat(400);
  world.queryPagesOk = 1;
  world.streamFail.query = { status: 500, code: -1 };
  await assertRejects(() => runEvent({ id: 35, event: "chat.erase", payload: { matchId: match } }));
  assertEquals(world.erased, []);
  assertEquals(calls("outbox_failed")[0].args.p_provider, "stream");
  assertEquals(calls("ack_event").length, 0);
});

Deno.test("chat.erase: only Stream's own 'gone' counts as gone", async () => {
  reset();
  world.rpcResults.chat_erase_due = true;
  world.channels[match] = chat(3);
  world.streamFail.delete = { status: 400, code: 4 };
  await assertRejects(() => runEvent({ id: 36, event: "chat.erase", payload: { matchId: match } }));
  assertEquals(calls("chat_erased").length, 0);

  world.streamFail.delete = { status: 404, code: 16 };
  world.rpc = [];
  await runEvent({ id: 36, event: "chat.erase", payload: { matchId: match }, steps: [] });
  assertEquals(calls("chat_erased").length, 1);
});

Deno.test("chat.erase: the due check failing fails the event, never acked as done", async () => {
  reset();
  world.channels[match] = chat(3);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.pathname.endsWith("/rpc/chat_erase_due")) return Promise.resolve(respond({ message: "boom" }, 500));
    return originalFetch(input, init);
  };
  try {
    await assertRejects(() => runEvent({ id: 37, event: "chat.erase", payload: { matchId: match } }));
  } finally {
    globalThis.fetch = originalFetch;
  }
  assertEquals(world.erased, []);
  assertEquals(calls("ack_event").length, 0);
});

Deno.test("chat.erase: a malformed id fails before anything is asked", async () => {
  reset();
  await assertRejects(() => runEvent({ id: 38, event: "chat.erase", payload: { matchId: "x,user_a.eq.y" } }));
  assertEquals(calls("chat_erase_due").length, 0);
});

Deno.test("account.purge: its chats, Stream user, media and selfies, then the Auth user; a retry repeats nothing", async () => {
  reset();
  world.rpcResults.retained_account_due = true;
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo }, { id: match2, user_a: ana, user_b: cy }];
  // The second chat never had a message: Stream has no channel.
  world.channels[match] = chat(3);
  world.objects = [`u/${ana}/photos/a.jpg`, `u/${ana}/chat/p1.jpg`, `u/${bo}/photos/b.jpg`];
  world.selfies = ["s1.jpg"];
  world.taskStatus = ["running", "completed"];
  const event = { id: 40, event: "account.purge", payload: { userId: ana } };
  await runEvent(event);
  const media = [`u/${ana}/chat/p1.jpg`, `u/${bo}/chat/v2.jpg`, `u/${bo}/chat/v2.mp4`]
    .flatMap(withRenditions).map((k) => `r2 ${k}`).sort();
  const n = media.length;
  assertEquals(world.erased.slice(0, n).sort(), media);
  assertEquals(world.erased.slice(n, n + 2), [`stream channel ${match} hard`, `stream user ${ana} hard`]);
  assertEquals(world.stream.filter((c) => c.startsWith("task")).length, 2, "waits for Stream's task");
  // Its prefix only (renditions are under it: listed, not guessed); its chat photo went with the chat.
  assertEquals(world.erased.slice(n + 2, n + 3), [`r2 u/${ana}/photos/a.jpg`]);
  assertEquals(world.erased.slice(n + 3), [`selfies ${ana}/s1.jpg`, `auth ${ana}`]);
  assertEquals(steps(40), [
    `matches=${match},${match2}`,
    `chat-${match}`,
    `chat-${match2}`,
    "chat-user",
    "media",
    "selfies",
    "auth",
  ]);
  assertEquals(calls("forget_selfies").length, 1);
  assertEquals(calls("chat_erased").map((c) => c.args.p_match), [match, match2]);

  // A retry after the Auth user went: no longer "due", but the rest still runs.
  world.erased = [];
  world.rpc = [];
  world.rpcResults.retained_account_due = false;
  world.tables.matches = [];
  await runEvent({
    ...event,
    steps: [`matches=${match},${match2}`, `chat-${match}`, `chat-${match2}`, "chat-user", "media", "selfies", "auth"],
  });
  assertEquals(world.erased, [], "only what was left");
  assertEquals(calls("retained_account_due").length, 0);
  assertEquals(calls("chat_erased").length, 2);
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("account.purge: a failed Stream task, the selfies bucket or the Auth user stops it before what follows", async () => {
  reset();
  world.rpcResults.retained_account_due = true;
  world.taskStatus = ["failed"];
  await assertRejects(() => runEvent({ id: 41, event: "account.purge", payload: { userId: ana } }));
  assertEquals(steps(41), ["matches="]);
  assertEquals(world.erased, [`stream user ${ana} hard`], "no media, no Auth deletion");

  reset();
  world.rpcResults.retained_account_due = true;
  world.selfies = ["s1.jpg"];
  world.storageFail = "remove";
  await assertRejects(() => runEvent({ id: 42, event: "account.purge", payload: { userId: ana } }));
  assertEquals(steps(42), ["matches=", "chat-user", "media"]);
  assertEquals(calls("forget_selfies").length, 0);
  assert(!world.erased.includes(`auth ${ana}`));

  reset();
  world.rpcResults.retained_account_due = true;
  world.authDeleteStatus = 500;
  await assertRejects(() => runEvent({ id: 43, event: "account.purge", payload: { userId: ana } }));
  assertEquals(steps(43).includes("auth"), false);
  assertEquals(calls("ack_event").length, 0);

  reset();
  world.rpcResults.retained_account_due = true;
  world.authDeleteStatus = 404;
  await runEvent({ id: 44, event: "account.purge", payload: { userId: ana } });
  assertEquals(steps(44).at(-1), "auth", "an Auth user gone already is done");
});

Deno.test("account.purge: a case reopened since keeps the account", async () => {
  reset();
  world.rpcResults.retained_account_due = false;
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo }];
  world.channels[match] = chat(3);
  await runEvent({ id: 45, event: "account.purge", payload: { userId: ana } });
  assertEquals(world.erased, []);
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("selfie.expired: a banned account's selfies go 6 months on, only when still due", async () => {
  reset();
  world.rpcResults.banned_selfies_due = true;
  world.selfies = ["s1.jpg", "s2.jpg"];
  await runEvent({ id: 46, event: "selfie.expired", payload: { userId: ana } });
  assertEquals(world.erased, [`selfies ${ana}/s1.jpg ${ana}/s2.jpg`]);
  assertEquals(calls("forget_selfies").length, 1);

  reset();
  world.rpcResults.banned_selfies_due = false;
  world.selfies = ["s1.jpg"];
  await runEvent({ id: 47, event: "selfie.expired", payload: { userId: ana } });
  assertEquals(world.erased, []);
  assertEquals(calls("ack_event").length, 1);

  reset();
  world.rpcResults.banned_selfies_due = true;
  world.selfies = ["s1.jpg"];
  world.storageFail = "remove";
  await assertRejects(() => runEvent({ id: 48, event: "selfie.expired", payload: { userId: ana } }));
  assertEquals(calls("forget_selfies").length, 0, "records kept while the files are");
});

Deno.test("match.ended: the chat is frozen; a channel Stream doesn't have is fine, another failure isn't", async () => {
  reset();
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo }];
  world.channels[match] = chat(1);
  await runEvent({ id: 49, event: "match.ended", payload: { matchId: match } });
  assertEquals(world.stream, [`leave ${match} ${ana} ${bo}`, `update ${match} {"frozen":true}`]);

  reset();
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo }];
  await runEvent({ id: 50, event: "match.ended", payload: { matchId: match } });
  assertEquals(calls("ack_event").length, 1);

  reset();
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo }];
  world.channels[match] = chat(1);
  world.streamFail.removeMembers = { status: 429, code: 9 };
  await assertRejects(() => runEvent({ id: 51, event: "match.ended", payload: { matchId: match } }));
});

Deno.test("chat.sweep: frozen channels are handed to the database page by page, resuming where it stopped", async () => {
  reset();
  world.frozen = Array.from({ length: 35 }, (_, i) => ({
    id: `c${String(i).padStart(2, "0")}`,
    created_at: `2025-01-${String(i % 28 + 1).padStart(2, "0")}T00:00:${String(i).padStart(2, "0")}Z`,
    updated_at: "2025-06-01T00:00:00Z",
  })).sort((a, b) => a.created_at.localeCompare(b.created_at));
  await runEvent({ id: 52, event: "chat.sweep", payload: {} });
  const tracked = calls("track_frozen_chats").map((c) => (c.args.p_chats as Row[]).length);
  assertEquals(tracked, [30, 5]);
  assertEquals((calls("track_frozen_chats")[0].args.p_chats as Row[])[0], {
    id: world.frozen[0].id,
    at: "2025-06-01T00:00:00Z",
  });
  assertEquals(steps(52), [`after=${world.frozen[29].created_at}`, `after=${world.frozen[34].created_at}`]);

  world.rpc = [];
  await runEvent({ id: 52, event: "chat.sweep", payload: {}, steps: [`after=${world.frozen[34].created_at}`] });
  assertEquals(calls("track_frozen_chats").length, 0, "nothing after the last one");
});

// MARK: Data exports (20260930000301)

function exportWorld() {
  people();
  world.rpcResults.export_begin = "go";
  world.rpcResults.export_stored = true;
  world.rpcResults.export_ready = true;
  world.rpcResults.export_data = {
    account: { id: ana, email: "ana@drafft.so" },
    profile: { id: ana, name: "Ana", voice_intro_key: `u/${ana}/voice/v.m4a` },
    media: [{ key: `u/${ana}/photos/1.jpg`, posterKey: null }],
    matches: [{ id: match }],
  };
  // 650 messages over three pages: Ana wrote the even ones.
  world.channels[match] = Array.from({ length: 650 }, (_, i) => ({
    id: `m${i}`,
    user: { id: i % 2 === 0 ? ana : bo },
    text: `message ${i}`,
    created_at: new Date(Date.UTC(2026, 8, 1, 0, i)).toISOString(),
  }));
  // Ana's photo in a chat, and a reaction she left on one of Bo's messages; Bo's photo stays his.
  world.channels[match][2].attachments = [{ type: "drafft_media", key: `u/${ana}/chat/c.jpg` }];
  world.channels[match][3].attachments = [{ type: "drafft_media", key: `u/${bo}/chat/b.jpg` }];
  world.channels[match][3].latest_reactions = [
    { type: "like", user: { id: ana }, created_at: "2026-09-02T00:00:00Z" },
    { type: "love", user: { id: bo }, created_at: "2026-09-02T00:00:00Z" },
  ];
}

function exported(path: string) {
  const files = unzipSync(world.exports[path]);
  const data = files["data.json"] ? JSON.parse(new TextDecoder().decode(files["data.json"])) : null;
  return { files: Object.keys(files).sort(), data };
}

Deno.test("export.requested: built, stored, emailed with a 7-day link in the person's language, then fulfilled", async () => {
  reset();
  exportWorld();
  const event = { id: 40, event: "export.requested", payload: { id: 77, userId: ana } };
  await runEvent(event);
  assertEquals(Object.keys(world.exports), [`${ana}/77-1.zip`], "one part when it all fits");
  const { files, data } = exported(`${ana}/77-1.zip`);
  assertEquals(files, ["data.json", "files/chat/c.jpg", "files/photos/1.jpg", "files/voice/v.m4a"]);
  assertEquals(data.messagesSent.length, 325, "every page, only what Ana sent");
  assertEquals(data.reactionsLeft, [{ match, message: "m3", type: "like", createdAt: "2026-09-02T00:00:00Z" }]);
  assertEquals(data.messagesSent[0].id, "m0");
  assertEquals(data.account.email, "ana@drafft.so");
  assertEquals(data.files, {
    parts: 1,
    list: [
      { path: "files/photos/1.jpg", bytes: 4, part: 1 },
      { path: "files/voice/v.m4a", bytes: 4, part: 1 },
      { path: "files/chat/c.jpg", bytes: 4, part: 1 },
    ],
  });
  assertEquals(
    world.emails.map(({ to, key }) => ({ to, key })),
    [{ to: "ana@drafft.so", key: "export-77" }],
    "no team copy when nothing is left out",
  );
  assertEquals(steps(40), ["parts=1", "email"]);
  assertEquals(calls("export_stored")[0].args, { p_id: 77, p_paths: [`${ana}/77-1.zip`] });
  assertEquals(calls("export_ready")[0].args, { p_id: 77 });

  // Replayed after the email: nothing is built or sent again.
  world.rpc = [];
  world.exports = {};
  await runEvent({ ...event, steps: ["parts=1", "email"] });
  assertEquals(world.exports, {});
  assertEquals(world.emails.length, 1);
  assertEquals(calls("export_ready").length, 1);
});

Deno.test("export.requested: another delivery building it is retried later; one fulfilled is done", async () => {
  reset();
  exportWorld();
  world.rpcResults.export_begin = "busy";
  await assertRejects(() => runEvent({ id: 41, event: "export.requested", payload: { id: 77, userId: ana } }));
  assertEquals(calls("export_data").length, 0);
  assertEquals(calls("ack_event").length, 0);

  world.rpc = [];
  world.rpcResults.export_begin = "done";
  await runEvent({ id: 42, event: "export.requested", payload: { id: 77, userId: ana } });
  assertEquals([calls("export_data").length, world.emails.length, calls("ack_event").length], [0, 0, 1]);
});

Deno.test("export.requested: over the limit, split in parts under it, in order, one link each", async () => {
  reset();
  exportWorld();
  const [photo, second, voice] = [`u/${ana}/photos/1.jpg`, `u/${ana}/photos/2.jpg`, `u/${ana}/voice/v.m4a`];
  (world.rpcResults.export_data as Row).media = [{ key: photo }, { key: second }];
  world.channels[match] = [];
  world.sizes = { [photo]: 30_000, [second]: 30_000, [voice]: 10_000 };
  // A part from an earlier attempt that split it in 4: deleted.
  world.exports[`${ana}/78-4.zip`] = new Uint8Array();
  Deno.env.set("EXPORT_MAX_BYTES", "50000");
  try {
    await runEvent({ id: 43, event: "export.requested", payload: { id: 78, userId: ana } });
  } finally {
    Deno.env.delete("EXPORT_MAX_BYTES");
  }
  const paths = [1, 2].map((n) => `${ana}/78-${n}.zip`);
  assertEquals(Object.keys(world.exports).sort(), paths);
  assertEquals(world.removed, [`${ana}/78-4.zip`]);
  for (const path of paths) assert(world.exports[path].length <= 50_000, `${path}: ${world.exports[path].length}`);
  const first = exported(paths[0]);
  assertEquals(first.files, ["data.json", "files/photos/1.jpg"], "part 1: data.json and the first files");
  assertEquals(first.data.messagesSent, [], "a chat with no message");
  assertEquals(first.data.files.parts, 2);
  assertEquals(first.data.files.list.map((f: Row) => [f.path, f.part]), [
    ["files/photos/1.jpg", 1],
    ["files/photos/2.jpg", 2],
    ["files/voice/v.m4a", 2],
  ]);
  assertEquals(exported(paths[1]), { files: ["files/photos/2.jpg", "files/voice/v.m4a"], data: null });
  assertEquals(
    world.emails.map(({ to, key }) => ({ to, key })),
    [{ to: "ana@drafft.so", key: "export-78" }],
    "one email, no team copy",
  );
  assertEquals(steps(43), ["parts=2", "email"]);
  assertEquals(calls("export_stored")[0].args, { p_id: 78, p_paths: paths });
});

Deno.test("export.requested: a file larger than a part on its own is listed with a note, and the team is told", async () => {
  reset();
  exportWorld();
  world.sizes = { [`u/${ana}/voice/v.m4a`]: 60_000, [`u/${ana}/chat/c.jpg`]: -1 };
  Deno.env.set("EXPORT_MAX_BYTES", "50000");
  try {
    await runEvent({ id: 44, event: "export.requested", payload: { id: 79, userId: ana } });
  } finally {
    Deno.env.delete("EXPORT_MAX_BYTES");
  }
  assertEquals(Object.keys(world.exports), [`${ana}/79-1.zip`]);
  const { files, data } = exported(`${ana}/79-1.zip`);
  assertEquals(files, ["data.json", "files/photos/1.jpg"]);
  assertEquals(data.files.list[1], {
    path: "files/voice/v.m4a",
    bytes: 60_000,
    part: null,
    note: "Too large for one part of this export: not included, the team sends it another way.",
  });
  assertEquals(data.files.list[2], {
    path: "files/chat/c.jpg",
    bytes: null,
    part: null,
    note: "Not found in storage: not included.",
  });
  assertEquals(world.emails.map((e) => e.to), ["ana@drafft.so", "team@drafft.so"]);
  assertEquals(steps(44), ["omitted=1,1", "parts=1", "email", "team-email"]);
});

Deno.test("export.expired: every part goes, the request remembers it", async () => {
  reset();
  world.rpcResults.export_files = [`${ana}/77-1.zip`, `${ana}/77-2.zip`];
  await runEvent({ id: 45, event: "export.expired", payload: { id: 77 } });
  assertEquals(world.removed, [`${ana}/77-1.zip`, `${ana}/77-2.zip`]);
  assertEquals(calls("export_file_deleted")[0].args, { p_id: 77 });
});

Deno.test("export.requested: no email address on the account: nothing built, the team told, the request closed", async () => {
  reset();
  exportWorld();
  world.users = {};
  await runEvent({ id: 46, event: "export.requested", payload: { id: 80, userId: ana } });
  assertEquals(calls("export_data").length, 0);
  assertEquals(world.exports, {});
  assertEquals(world.emails.map((e) => e.to), ["team@drafft.so"]);
  assertEquals(calls("export_closed")[0].args, { p_id: 80, p_reason: "no_email" });
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("export.requested: the account erased while it was built: its parts are deleted, no email", async () => {
  reset();
  exportWorld();
  world.rpcResults.export_stored = false;
  await runEvent({ id: 47, event: "export.requested", payload: { id: 81, userId: ana } });
  assertEquals(world.removed, [`${ana}/81-1.zip`]);
  assertEquals(world.emails, []);
  assertEquals(calls("export_ready").length, 0);
});

Deno.test("export.requested: Stream failing is an error, never an export without messages", async () => {
  reset();
  exportWorld();
  world.streamFail.query = { status: 401, code: 5 };
  await assertRejects(() => runEvent({ id: 48, event: "export.requested", payload: { id: 82, userId: ana } }));
  assertEquals(world.exports, {});
  assertEquals(calls("ack_event").length, 0);

  // A match without a channel (nobody wrote): no messages, not an error.
  reset();
  exportWorld();
  delete world.channels[match];
  await runEvent({ id: 49, event: "export.requested", payload: { id: 83, userId: ana } });
  assertEquals(exported(`${ana}/83-1.zip`).data.messagesSent, []);
});

Deno.test("export.requested: a limit that isn't a number of bytes, or data.json alone over it, fails clearly", async () => {
  for (const [limit, message] of [["45MB", "EXPORT_MAX_BYTES must be a number of bytes"], ["300", "data.json alone"]]) {
    reset();
    exportWorld();
    Deno.env.set("EXPORT_MAX_BYTES", limit);
    try {
      await assertRejects(
        () => runEvent({ id: 50, event: "export.requested", payload: { id: 84, userId: ana } }),
        Error,
        message,
      );
    } finally {
      Deno.env.delete("EXPORT_MAX_BYTES");
    }
    assertEquals(world.exports, {});
  }
});

Deno.test("export.sweep: parts no request refers to are deleted, nothing else", async () => {
  reset();
  await runEvent({
    id: 51,
    event: "export.sweep",
    payload: { paths: [`${ana}/90-1.zip`, "../elsewhere/x.zip", `${ana}/notes.txt`] },
  });
  assertEquals(world.removed, [`${ana}/90-1.zip`]);
});

// MARK: Statements of reasons (20260930000401)

function decision(kind: string, target: string | null = null, details: string | null = "Keep it friendly, please.") {
  world.rpcResults.moderation_decision = [{
    user_id: ana,
    kind,
    category: "harassment",
    terms_anchor: "community",
    details,
    target,
    language: "fr",
  }];
}

Deno.test("moderation.decision: a ban is emailed with its reason and how to contest it, and pushed", async () => {
  reset();
  people();
  decision("account_banned");
  await runEvent({ id: 50, event: "moderation.decision", payload: { id: 7 }, pushUntil: inAnHour() });
  assertEquals(world.emails.length, 1);
  const [email] = world.emails;
  assertEquals([email.to, email.key, email.replyTo], ["ana@drafft.so", "decision-7", "team@drafft.so"]);
  assertEquals(email.subject, "Ton compte drafft est fermé");
  assert(email.text?.includes("Pourquoi\u00A0: harceler, menacer ou insulter quelqu'un."), "the reason, in French");
  assert(email.text?.includes("Keep it friendly, please."), "the team's note, as written");
  assert(email.text?.includes("La règle\u00A0: Règles de la communauté"), "the rule, by its section");
  assert(email.text?.includes("https://getdrafft.com/fr/terms#community"), "with a link to it, in French");
  assert(email.text?.includes("Centre d'aide"), "how to contest it");
  assertEquals(world.pushes.map((p) => p.collapse), [`moderation-${ana}`]);
  assertEquals(steps(50), ["email", "push"]);
});

Deno.test("moderation.decision: a refused photo is emailed only (its push already went)", async () => {
  reset();
  people();
  decision("photo_refused", media, null);
  await runEvent({ id: 51, event: "moderation.decision", payload: { id: 8 }, pushUntil: inAnHour() });
  assertEquals(world.emails.map((e) => e.key), ["decision-8"]);
  assert(!world.emails[0].text?.includes("Un mot de l'équipe"), "no note when the team wrote none");
  assertEquals(world.pushes, []);
});

Deno.test("moderation.decision: a selfie asked for is emailed only (account.moderation pushes it)", async () => {
  reset();
  people();
  (world.tables.profiles[0] as Row).moderation = "selfie";
  decision("account_selfie");
  await runEvent({ id: 56, event: "moderation.decision", payload: { id: 12 }, pushUntil: inAnHour() });
  assertEquals(world.emails.map((e) => e.key), ["decision-12"]);
  assertEquals(world.pushes, []);
});

Deno.test("moderation.decision: a selfie asked again is emailed and pushed, while it is still due", async () => {
  reset();
  people();
  (world.tables.profiles[0] as Row).moderation = "selfie";
  decision("account_selfie");
  await runEvent({ id: 57, event: "moderation.decision", payload: { id: 13, repeat: true }, pushUntil: inAnHour() });
  assertEquals(world.emails.map((e) => e.key), ["decision-13"]);
  assert(world.emails[0].text?.includes("Keep it friendly, please."), "the new note, as written");
  assertEquals(world.pushes.map((p) => [p.collapse, p.title]), [[`moderation-${ana}`, "Vérification par selfie"]]);
  assertEquals(steps(57), ["email", "push"]);

  reset();
  people();
  (world.tables.profiles[0] as Row).moderation = "review";
  decision("account_selfie");
  await runEvent({ id: 58, event: "moderation.decision", payload: { id: 14, repeat: true }, pushUntil: inAnHour() });
  assertEquals(world.emails.map((e) => e.key), ["decision-14"], "the statement still goes");
  assertEquals(world.pushes, [], "no push once the selfie was sent or the hold lifted");
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("moderation.decision: a removed message is told once Stream shows it removed", async () => {
  reset();
  people();
  decision("message_deleted", `${match}/msg-1`);
  world.messages["msg-1"] = { id: "msg-1", type: "regular" };
  const event = { id: 52, event: "moderation.decision", payload: { id: 9 }, pushUntil: inAnHour() };
  await assertRejects(() => runEvent(event));
  assertEquals([world.emails.length, world.pushes.length, calls("ack_event").length], [0, 0, 0], "not yet");

  world.messages["msg-1"] = { id: "msg-1", type: "deleted", deleted_at: new Date().toISOString() };
  world.rpc = [];
  await runEvent(event);
  assertEquals(world.emails.map((e) => e.key), ["decision-9"]);
  assertEquals(world.pushes.map((p) => p.collapse), ["decision-9"]);
  assertEquals(steps(52), ["removed", "email", "push"]);
});

Deno.test("moderation.decision: an account erased since is acked without a word", async () => {
  reset();
  world.rpcResults.moderation_decision = [];
  await runEvent({ id: 53, event: "moderation.decision", payload: { id: 10 } });
  assertEquals([world.emails.length, calls("ack_event").length], [0, 1]);
});

Deno.test("notices: a reply to a moderation email reaches the team", async () => {
  reset();
  people();
  (world.tables.profiles[0] as Row).moderation = null;
  await runEvent({ id: 54, event: "account.moderation", payload: { userId: ana, previous: "review" } });
  assertEquals(world.emails.map((e) => e.replyTo), ["team@drafft.so"]);
});

Deno.test("moderation.decision: without an email address, the push says it all and points to no email", async () => {
  reset();
  people();
  world.users = {};
  decision("account_review");
  await runEvent({ id: 55, event: "moderation.decision", payload: { id: 11 }, pushUntil: inAnHour() });
  assertEquals(world.emails, []);
  assertEquals(world.pushes.length, 1);
  assertEquals(steps(55), ["push"]);
});

Deno.test("moderation.decision: a message Stream can't tell about is retried, never told as removed", async () => {
  reset();
  people();
  decision("message_deleted", `${match}/msg-2`);
  world.streamFail.getMessage = { status: 500, code: -1 };
  await assertRejects(() => runEvent({ id: 56, event: "moderation.decision", payload: { id: 12 } }));
  assertEquals(world.emails, []);

  // Gone altogether (404, code 16): removed.
  reset();
  people();
  decision("message_deleted", `${match}/msg-3`);
  await runEvent({ id: 57, event: "moderation.decision", payload: { id: 13 }, pushUntil: inAnHour() });
  assertEquals(world.emails.map((e) => e.key), ["decision-13"]);
});

Deno.test("moderation.decision: a category this code doesn't know fails, never told as a vaguer reason", async () => {
  reset();
  people();
  decision("account_banned");
  (world.rpcResults.moderation_decision as Row[])[0].category = "new_rule";
  await assertRejects(() => runEvent({ id: 58, event: "moderation.decision", payload: { id: 14 } }));
  assertEquals(world.emails, []);
});

Deno.test("media.reviewed: a refusal by a person is pushed; its email is the statement, not a second one", async () => {
  reset();
  people();
  world.tables.profile_media = [{ id: media, status: "rejected" }];
  await runEvent({
    id: 59,
    event: "media.reviewed",
    payload: { mediaId: media, userId: ana, status: "rejected", secondLook: true, at: "1" },
    pushUntil: inAnHour(),
  });
  assertEquals(world.emails, []);
  assertEquals(world.pushes.length, 1);
});

Deno.test("media.reviewed: an approval has the photo's main renditions made at once", async () => {
  reset();
  people();
  const key = `u/${ana}/photos/a1.jpg`;
  world.tables.profile_media = [{ id: media, status: "approved", key }];
  await runEvent({
    id: 60,
    event: "media.reviewed",
    payload: { mediaId: media, userId: ana, status: "approved", secondLook: false, at: "1" },
  });
  assertEquals(world.warmed.sort(), [`${key} w1080`, `${key} w1440`, `${key} w320`]);
  assertEquals(world.pushes, []);
});

Deno.test("media.deleted: the photo first, then every rendition the Worker may have kept", async () => {
  reset();
  const key = `u/${ana}/photos/a1.jpg`;
  await runEvent({ id: 61, event: "media.deleted", payload: { keys: [key, `u/${ana}/voice/v.m4a`] } });
  assertEquals(world.erased.slice(0, 2).sort(), [`r2 ${key}`, `r2 u/${ana}/voice/v.m4a`]);
  assertEquals(world.erased.slice(2).sort(), withRenditions(key).slice(1).map((k) => `r2 ${k}`).sort());
});

Deno.test("renderDecision: the team's note is escaped and keeps its lines; the rules without a section link the terms", () => {
  const email = renderDecision("en", "account_banned", "other", null, "<b>x</b>\nline 2");
  assert(email.html.includes("&lt;b&gt;x&lt;/b&gt;<br>line 2"), email.html);
  assert(email.text.includes("The rules are in drafft's terms of use.\nhttps://getdrafft.com/terms\n"), email.text);
});

// MARK: Deleting an account on the member's request (20260930000601)

function staffDeletion(emails = ["ana@drafft.so", "ana.other@mail.fr"], outcome: string | null = null) {
  world.rpcResults.staff_deletion = [{ user_id: ana, reference: "DR-ABC234", emails, language: "fr", outcome }];
  world.rpcResults.retain_deleted_account = { retained: false };
  world.rpcResults.deleted_account_chats = { keep: [], erase: [] };
  world.objects = [`u/${ana}/photos/1.jpg`];
}

Deno.test("account.staff_delete: the app's deletion, its outcome recorded, then one confirmation to each address", async () => {
  reset();
  staffDeletion();
  Deno.env.set("SUPPORT_ADDRESS", "support@drafft.so");
  try {
    await runEvent({ id: 60, event: "account.staff_delete", payload: { id: 5 } });
  } finally {
    Deno.env.delete("SUPPORT_ADDRESS");
  }
  assertEquals(world.erased, [`stream user ${ana} hard`, `r2 u/${ana}/photos/1.jpg`, `auth ${ana}`]);
  assertEquals(calls("retain_deleted_account").length, 2, "asked before and after erasing, like delete-account");
  assertEquals(calls("staff_deletion_done")[0].args, { p_id: 5, p_outcome: "erased" });
  assertEquals(world.sent, [
    { to: "ana@drafft.so", subject: "Ton compte drafft est supprimé", replyTo: "support@drafft.so" },
    { to: "ana.other@mail.fr", subject: "Ton compte drafft est supprimé", replyTo: "support@drafft.so" },
  ]);
  assertEquals(steps(60), ["outcome=erased", "email-0", "email-1"]);
  assertEquals(calls("staff_deletion_emailed").length, 1, "the addresses are cleared");

  // Replayed: nothing deleted or sent again.
  world.erased = [];
  world.rpc = [];
  world.rpcResults.staff_deletion = [{ ...(world.rpcResults.staff_deletion as Row[])[0], outcome: "erased" }];
  await runEvent({
    id: 60,
    event: "account.staff_delete",
    payload: { id: 5 },
    steps: ["outcome=erased", "email-0", "email-1"],
  });
  assertEquals([world.erased, world.sent.length], [[], 2]);
});

Deno.test("account.staff_delete: kept for safety, nothing erased, the member confirmed all the same", async () => {
  reset();
  staffDeletion(["ana@drafft.so"]);
  world.rpcResults.retain_deleted_account = { retained: true, basis: "report" };
  await runEvent({ id: 61, event: "account.staff_delete", payload: { id: 6 } });
  assertEquals(world.erased, []);
  assertEquals(calls("staff_deletion_done")[0].args, { p_id: 6, p_outcome: "kept" });
  assertEquals(world.sent.map((e) => [e.to, e.replyTo]), [["ana@drafft.so", "team@drafft.so"]]);
});

Deno.test("account.staff_delete: failing midway sends nothing; the retry erases and confirms", async () => {
  reset();
  staffDeletion(["ana@drafft.so"]);
  world.r2DeleteStatus = 403;
  await assertRejects(() => runEvent({ id: 62, event: "account.staff_delete", payload: { id: 7 } }));
  assertEquals([steps(62), world.sent, calls("staff_deletion_done")], [[], [], []]);
  assert(!world.erased.includes(`auth ${ana}`), "the account is still there");

  world.r2DeleteStatus = 204;
  await runEvent({ id: 62, event: "account.staff_delete", payload: { id: 7 } });
  assertEquals(world.sent.map((e) => e.to), ["ana@drafft.so"]);
});

Deno.test("account.staff_delete: email down after the erasure: the retry only sends it", async () => {
  reset();
  staffDeletion(["ana@drafft.so"]);
  world.emailOutcome = ["down"];
  await assertRejects(() => runEvent({ id: 63, event: "account.staff_delete", payload: { id: 8 } }));
  assertEquals(steps(63), ["outcome=erased"]);
  world.rpc = [];
  world.erased = [];
  world.rpcResults.staff_deletion = [{ ...(world.rpcResults.staff_deletion as Row[])[0], outcome: "erased" }];
  await runEvent({ id: 63, event: "account.staff_delete", payload: { id: 8 }, steps: ["outcome=erased"] });
  assertEquals([calls("retain_deleted_account").length, world.erased, calls("staff_deletion_done").length], [0, [], 0]);
  assertEquals(world.sent.map((e) => e.to), ["ana@drafft.so"]);
});

Deno.test("account.staff_delete: no address at all: the team is told; a deletion gone since is acked", async () => {
  reset();
  staffDeletion([]);
  await runEvent({ id: 64, event: "account.staff_delete", payload: { id: 9 } });
  assertEquals(world.sent.map((e) => [e.to, e.subject]), [[
    "team@drafft.so",
    "[account deleted] no address to confirm to",
  ]]);
  assertEquals(calls("staff_deletion_emailed").length, 1);

  reset();
  world.rpcResults.staff_deletion = [];
  await runEvent({ id: 65, event: "account.staff_delete", payload: { id: 10 } });
  assertEquals([calls("retain_deleted_account").length, calls("ack_event").length], [0, 1]);
});
