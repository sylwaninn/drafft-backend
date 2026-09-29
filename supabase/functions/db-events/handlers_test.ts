// db-events handlers under partial failure (FLOW-09): an event that fails halfway is retried (or replayed
// from sophros) with the steps it already did, and no side effect happens twice or gets lost.
//
//   cd supabase/functions && deno test --allow-env --allow-read=. db-events/
//
// No network: fetch is replaced by a small world (PostgREST, Auth admin, APNs, Resend, R2, Rekognition)
// and Stream by a fake client. Everything they're asked is recorded.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";

// A throwaway P-256 key for the APNs provider token.
const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;

const ENV: Record<string, string> = {
  SUPABASE_URL: "http://supabase.test",
  SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
  SUPABASE_SECRET_KEYS: "",
  APNS_KEY_ID: "KEY",
  APNS_TEAM_ID: "TEAM",
  APNS_BUNDLE_ID: "so.drafft.app",
  APNS_PRIVATE_KEY: pem,
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
};
for (const [name, value] of Object.entries(ENV)) Deno.env.set(name, value);
for (const name of ["MAILPIT_URL", "EMAIL_REAL", "MODERATION_MODE"]) Deno.env.delete(name);

// MARK: The world

type Row = Record<string, unknown>;
type Outcome = "ok" | "down" | "network";

const world = {
  tables: {} as Record<string, Row[]>,
  users: {} as Record<string, string>,
  rpc: [] as { name: string; args: Row }[],
  rpcResults: {} as Record<string, unknown>,
  failRead: undefined as string | undefined,
  pushes: [] as { token: string; collapse: string | null }[],
  pushOutcome: {} as Record<string, Outcome>,
  emails: [] as { to: string; key: string | null }[],
  emailOutcome: [] as Outcome[],
  rekognition: 0,
  labels: [] as { Name: string; ParentName: string; Confidence: number }[],
  stream: [] as string[],
  streamUsers: [] as Row[],
  /** Stream channels by id: their messages. */
  channels: {} as Record<string, Row[]>,
  /** R2 keys that exist, and the outside deletions (R2, selfies bucket, Stream, Auth), in order. */
  objects: [] as string[],
  selfies: [] as string[],
  erased: [] as string[],
};

function reset() {
  world.tables = {};
  world.users = {};
  world.rpc = [];
  world.rpcResults = {};
  world.failRead = undefined;
  world.pushes = [];
  world.pushOutcome = {};
  world.emails = [];
  world.emailOutcome = [];
  world.rekognition = 0;
  world.labels = [];
  world.stream = [];
  world.streamUsers = [];
  world.channels = {};
  world.objects = [];
  world.selfies = [];
  world.erased = [];
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
  const text = request.method === "GET" || request.method === "HEAD" ? "" : await request.text();

  if (url.host === "supabase.test") {
    if (url.pathname.startsWith("/rest/v1/rpc/")) {
      const name = url.pathname.slice("/rest/v1/rpc/".length);
      world.rpc.push({ name, args: text ? JSON.parse(text) : {} });
      return respond(world.rpcResults[name] ?? null);
    }
    if (url.pathname.startsWith("/auth/v1/admin/users/") && request.method === "DELETE") {
      world.erased.push(`auth ${url.pathname.split("/").pop()}`);
      return respond({});
    }
    if (url.pathname === "/storage/v1/object/list/verification-selfies") {
      return respond(world.selfies.map((name) => ({ name })));
    }
    if (url.pathname === "/storage/v1/object/verification-selfies" && request.method === "DELETE") {
      world.erased.push(`selfies ${(JSON.parse(text) as { prefixes: string[] }).prefixes.join(" ")}`);
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
    return respond(undefined, 204);
  }

  if (url.host.endsWith("push.apple.com")) {
    const token = url.pathname.split("/").pop()!;
    const outcome = world.pushOutcome[token] ?? "ok";
    if (outcome === "network") throw new TypeError("error sending request: connection refused");
    if (outcome === "down") return respond({ reason: "ServiceUnavailable" }, 503);
    world.pushes.push({ token, collapse: request.headers.get("apns-collapse-id") });
    return respond(undefined, 200);
  }

  if (url.host === "api.resend.com") {
    const outcome = world.emailOutcome.shift() ?? "ok";
    if (outcome === "network") throw new TypeError("error sending request: connection reset");
    if (outcome === "down") return respond({ message: "service unavailable" }, 503);
    const body = JSON.parse(text) as { to: string[] };
    world.emails.push({ to: body.to[0], key: request.headers.get("idempotency-key") });
    return respond({ id: crypto.randomUUID() });
  }

  if (url.host.endsWith("r2.cloudflarestorage.com")) {
    if (url.searchParams.get("list-type") === "2") {
      const prefix = url.searchParams.get("prefix") ?? "";
      const keys = world.objects.filter((k) => k.startsWith(prefix)).map((k) => `<Key>${k}</Key>`).join("");
      return new Response(`<ListBucketResult>${keys}</ListBucketResult>`, { status: 200 });
    }
    if (request.method === "DELETE") {
      world.erased.push(`r2 ${decodeURIComponent(url.pathname.split("/").slice(2).join("/"))}`);
      return new Response(null, { status: 204 });
    }
    if (request.method === "HEAD") return new Response(null, { status: 200, headers: { "content-length": "4" } });
    return new Response(new Uint8Array([1, 2, 3, 4]), { status: 200 });
  }

  if (url.host.startsWith("rekognition.")) {
    world.rekognition++;
    return respond({ ModerationLabels: world.labels });
  }

  throw new Error(`unexpected fetch in a test: ${request.method} ${url}`);
};

// Stream: channels and messages by id, like the real thing (a duplicate id is refused).
const messages = new Set<string>();
const fakeStream = {
  channel: (_type: string, id: string) => ({
    create: () => {
      world.stream.push(`create ${id}`);
      return Promise.resolve({});
    },
    delete: (options?: { hard_delete?: boolean }) => {
      if (!world.channels[id]) {
        return Promise.reject(Object.assign(new Error("channel does not exist"), { status: 404 }));
      }
      delete world.channels[id];
      world.erased.push(`stream channel ${id}${options?.hard_delete ? " hard" : ""}`);
      return Promise.resolve({});
    },
    // Oldest first, `limit` of them before `id_lt`, like the real thing; an unknown channel is a 404.
    query: (options: { messages?: { limit?: number; id_lt?: string } }) => {
      const all = world.channels[id];
      if (!all) return Promise.reject(Object.assign(new Error(`Can't find channel ${id}`), { status: 404 }));
      const end = options.messages?.id_lt ? all.findIndex((m) => m.id === options.messages?.id_lt) : all.length;
      const limit = options.messages?.limit ?? 25;
      return Promise.resolve({ messages: all.slice(Math.max(0, end - limit), end) });
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
    world.erased.push(`stream user ${ids.join(" ")} ${options.user}`);
    return Promise.resolve({ task_id: "t" });
  },
};

const { useStreamClientForTests } = await import("../_shared/stream.ts");
useStreamClientForTests(fakeStream);
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

/** A chat of `n` messages, one of them with a photo, another with a video and its poster. */
function chat(n: number, sender = ana): Row[] {
  return Array.from({ length: n }, (_, i) => ({
    id: `m${i}`,
    attachments: i === 1
      ? [{ type: "drafft_media", key: `u/${sender}/chat/p${i}.jpg` }]
      : i === n - 1
      ? [{ type: "drafft_media", key: `u/${bo}/chat/v${i}.mp4`, poster_key: `u/${bo}/chat/v${i}.jpg` }]
      : [],
  }));
}

Deno.test("chat.erase: every page's media, whoever sent it, then the channel, for good", async () => {
  reset();
  world.rpcResults.chat_erase_due = true;
  world.channels[match] = chat(650);
  // Not a chat object: never deleted from a chat's erasure.
  world.channels[match][5].attachments = [{ type: "drafft_media", key: `u/${ana}/photos/profile.jpg` }];
  await runEvent({ id: 30, event: "chat.erase", payload: { matchId: match } });
  // Media first (in any order: 20 at a time), the channel last.
  assertEquals(world.erased.slice(0, 3).sort(), [
    `r2 u/${ana}/chat/p1.jpg`,
    `r2 u/${bo}/chat/v649.jpg`,
    `r2 u/${bo}/chat/v649.mp4`,
  ]);
  assertEquals(world.erased.slice(3), [`stream channel ${match} hard`]);
  assertEquals(steps(30), ["chat"]);
  assertEquals(calls("chat_erased")[0].args, { p_match: match });
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("chat.erase: a channel Stream never had is done; one not due is left alone", async () => {
  reset();
  world.rpcResults.chat_erase_due = true;
  await runEvent({ id: 31, event: "chat.erase", payload: { matchId: match } });
  assertEquals(world.erased, []);
  assertEquals(calls("chat_erased").length, 1, "nothing left to track");

  reset();
  world.rpcResults.chat_erase_due = false;
  world.channels[match] = chat(3);
  await runEvent({ id: 32, event: "chat.erase", payload: { matchId: match } });
  assertEquals(world.erased, []);
  assertEquals(calls("chat_erased").length, 0);
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("account.purge: its chats, Stream user, media and selfies, then the Auth user; a retry repeats nothing", async () => {
  reset();
  world.rpcResults.retained_account_due = true;
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo }];
  world.channels[match] = chat(3);
  world.objects = [`u/${ana}/photos/a.jpg`, `u/${ana}/chat/p1.jpg`, `u/${bo}/photos/b.jpg`];
  world.selfies = ["s1.jpg"];
  const event = { id: 33, event: "account.purge", payload: { userId: ana } };
  await runEvent(event);
  assertEquals(world.erased.slice(0, 3).sort(), [
    `r2 u/${ana}/chat/p1.jpg`,
    `r2 u/${bo}/chat/v2.jpg`,
    `r2 u/${bo}/chat/v2.mp4`,
  ]);
  assertEquals(world.erased.slice(3, 5), [`stream channel ${match} hard`, `stream user ${ana} hard`]);
  assertEquals(
    world.erased.slice(5, 7).sort(),
    [`r2 u/${ana}/chat/p1.jpg`, `r2 u/${ana}/photos/a.jpg`],
    "its prefix only",
  );
  assertEquals(world.erased.slice(7), [`selfies ${ana}/s1.jpg`, `auth ${ana}`]);
  assertEquals(steps(33), [`chat-${match}`, "chat-user", "media", "selfies"]);
  assertEquals(calls("chat_erased")[0].args, { p_match: match });

  world.erased = [];
  world.rpc = [];
  world.rpcResults.retained_account_due = true;
  await runEvent({ ...event, steps: [`chat-${match}`, "chat-user", "media", "selfies"] });
  assertEquals(world.erased, [`auth ${ana}`], "only what was left");
});

Deno.test("account.purge: a case reopened since keeps the account", async () => {
  reset();
  world.rpcResults.retained_account_due = false;
  world.tables.matches = [{ id: match, user_a: ana, user_b: bo }];
  world.channels[match] = chat(3);
  await runEvent({ id: 34, event: "account.purge", payload: { userId: ana } });
  assertEquals(world.erased, []);
  assertEquals(calls("ack_event").length, 1);
});

Deno.test("selfie.expired: a banned account's selfies go 6 months on, only when still due", async () => {
  reset();
  world.rpcResults.banned_selfies_due = true;
  world.rpcResults.selfie_paths = [`${ana}/s1.jpg`];
  await runEvent({ id: 35, event: "selfie.expired", payload: { userId: ana } });
  assertEquals(world.erased, [`selfies ${ana}/s1.jpg`]);
  assertEquals(calls("forget_selfies").length, 1);

  reset();
  world.rpcResults.banned_selfies_due = false;
  await runEvent({ id: 36, event: "selfie.expired", payload: { userId: ana } });
  assertEquals(calls("selfie_paths").length, 0);
  assertEquals(calls("ack_event").length, 1);
});
