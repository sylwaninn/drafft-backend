// delete-account: an account the database keeps (reported, held, banned) is never erased; any other is, through
// the shared erasure (_shared/erase.ts).
//
//   cd supabase/functions && deno test --allow-env --allow-read=. _tests/
//
// No network: fetch answers Supabase (Auth, the RPCs, Storage) and R2 from a script, and Stream is a fake
// client. Every call is recorded, in order.
import { assertEquals } from "jsr:@std/assert@1";

const ENV: Record<string, string> = {
  SUPABASE_URL: "http://supabase.test",
  SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
  SUPABASE_SECRET_KEYS: "",
  STREAM_API_KEY: "test-stream-key",
  STREAM_API_SECRET: "test-stream-secret",
  R2_ACCESS_KEY_ID: "r2",
  R2_SECRET_ACCESS_KEY: "r2",
  R2_ACCOUNT_ID: "acct",
  R2_BUCKET: "media",
};
for (const [name, value] of Object.entries(ENV)) Deno.env.set(name, value);

const USER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const calls: string[] = [];
/** What retain_deleted_account answers, call after call. */
let retainAnswers: boolean[] = [];
/** What deleted_account_chats answers. */
let chatsAnswer: { keep: { match: string; other: string }[]; erase: string[] } = { keep: [], erase: [] };
/** Channels Stream has, and the status of its deletion tasks. */
let channels: Record<string, { id: string; user: { id: string }; attachments: unknown[] }[]> = {};
let taskStatus = "completed";
/** The account's export parts in the data-exports bucket. */
let exportParts: string[] = [];
/** The data-exports bucket: there, missing from the project, or failing. */
let exportsBucket: "ok" | "missing" | "down" = "ok";

globalThis.fetch = async (input: Request | URL | string, init?: RequestInit): Promise<Response> => {
  const request = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(request.url);
  if (url.host.endsWith("r2.cloudflarestorage.com")) {
    if (url.searchParams.get("list-type") === "2") {
      calls.push(`r2 list ${url.searchParams.get("prefix")}`);
      return new Response(`<ListBucketResult><Key>u/${USER}/photos/photo.jpg</Key></ListBucketResult>`);
    }
    calls.push(`r2 ${request.method.toLowerCase()} ${decodeURIComponent(url.pathname.split("/").slice(2).join("/"))}`);
    return new Response(null, { status: 204 });
  }
  const call = `${request.method} ${url.pathname}`;
  calls.push(call);
  if (call === "GET /auth/v1/user") return Response.json({ id: USER, aud: "authenticated", role: "authenticated" });
  if (call === "POST /rest/v1/rpc/retain_deleted_account") {
    assertEquals(await request.json(), { p_user: USER });
    return Response.json({ retained: retainAnswers.shift() ?? false });
  }
  if (call === "POST /rest/v1/rpc/deleted_account_chats") {
    assertEquals(await request.json(), { p_user: USER });
    return Response.json(chatsAnswer);
  }
  if (call === "POST /rest/v1/rpc/forget_selfies") return Response.json(null);
  if (call === "POST /storage/v1/object/list/verification-selfies") return Response.json([]);
  // An export in two parts: the folder holds both, and both go.
  if (call === "POST /storage/v1/object/list/data-exports" && exportsBucket !== "ok") {
    return exportsBucket === "missing"
      ? Response.json({ statusCode: "404", error: "Bucket not found", message: "Bucket not found" }, { status: 400 })
      : Response.json({ statusCode: "500", error: "boom", message: "boom" }, { status: 500 });
  }
  if (call === "POST /storage/v1/object/list/data-exports") {
    return Response.json(exportParts.splice(0).map((name) => ({ name })));
  }
  if (call === "DELETE /storage/v1/object/data-exports") {
    assertEquals(await request.json(), { prefixes: [`${USER}/7-1.zip`, `${USER}/7-2.zip`] });
    return Response.json([]);
  }
  if (call === `DELETE /auth/v1/admin/users/${USER}`) return Response.json({});
  return Promise.reject(new Error(`unexpected fetch in a test: ${call}`));
};

function gone(what: string) {
  return Promise.reject(Object.assign(new Error(`StreamChat error code 16: ${what} does not exist`), {
    status: 404,
    code: 16,
  }));
}

const fakeStream = {
  channel: (_type: string, id: string) => ({
    query: () => Promise.resolve({ messages: channels[id] ?? [] }),
    delete: () =>
      channels[id] ? (calls.push(`stream delete ${id}`), delete channels[id], Promise.resolve({})) : gone(id),
    removeMembers: (ids: string[]) => (calls.push(`stream leave ${id} ${ids.join(" ")}`), Promise.resolve({})),
    updatePartial: () => (calls.push(`stream freeze ${id}`), Promise.resolve({})),
  }),
  queryChannelsRequest: (filter: { id: { $eq: string } }) =>
    Promise.resolve(channels[filter.id.$eq] ? [{ channel: { id: filter.id.$eq } }] : []),
  deleteUsers: (ids: string[], options: { user: string }) => (
    calls.push(`stream ${options.user} ${ids.join(" ")}`), Promise.resolve({ task_id: "t1" })
  ),
  getTask: () => Promise.resolve({ status: taskStatus }),
};

const { useStreamClientForTests } = await import("../_shared/stream.ts");
useStreamClientForTests(fakeStream);
const { timing } = await import("../_shared/erase.ts");
timing.sleep = () => Promise.resolve();

type Handler = (req: Request) => Response | Promise<Response>;
let handler: Handler | undefined;
const serve = Deno.serve;
// deno-lint-ignore no-explicit-any
(Deno as any).serve = (h: Handler) => {
  handler = h;
  return { finished: Promise.resolve(), shutdown: () => Promise.resolve(), ref() {}, unref() {} };
};
await import("../delete-account/index.ts");
Deno.serve = serve;

async function deleteAccount(answers: boolean[], chats = { keep: [], erase: [] } as typeof chatsAnswer) {
  calls.length = 0;
  retainAnswers = answers;
  chatsAnswer = chats;
  const response = await handler!(
    new Request("http://functions.test/delete-account", {
      method: "POST",
      headers: { authorization: "Bearer a-valid-token" },
    }),
  );
  await response.body?.cancel();
  return response.status;
}

Deno.test("reported, held or banned: kept, nothing erased", async () => {
  assertEquals(await deleteAccount([true]), 204);
  assertEquals(calls, ["GET /auth/v1/user", "POST /rest/v1/rpc/retain_deleted_account"]);
});

Deno.test("any other account: chats, Stream user, media, selfies, exports and the auth user erased, in that order", async () => {
  exportParts = ["7-1.zip", "7-2.zip"];
  channels = {
    "plain-chat": [{
      id: "m1",
      user: { id: OTHER },
      attachments: [{ type: "drafft_media", key: `u/${OTHER}/chat/x.jpg` }],
    }],
  };
  assertEquals(await deleteAccount([false, false], { keep: [], erase: ["plain-chat", "never-written"] }), 204);
  assertEquals(calls, [
    "GET /auth/v1/user",
    "POST /rest/v1/rpc/retain_deleted_account",
    "POST /rest/v1/rpc/deleted_account_chats",
    `r2 delete u/${OTHER}/chat/x.jpg`,
    "stream delete plain-chat",
    `stream hard ${USER}`,
    `r2 list u/${USER}/`,
    `r2 delete u/${USER}/photos/photo.jpg`,
    "POST /storage/v1/object/list/verification-selfies",
    "POST /rest/v1/rpc/forget_selfies",
    "POST /storage/v1/object/list/data-exports",
    "DELETE /storage/v1/object/data-exports",
    "POST /rest/v1/rpc/retain_deleted_account",
    `DELETE /auth/v1/admin/users/${USER}`,
  ]);
});

Deno.test("reported while being erased: the auth user and its rows are kept", async () => {
  assertEquals(await deleteAccount([false, true]), 204);
  assertEquals(calls.includes(`DELETE /auth/v1/admin/users/${USER}`), false);
  assertEquals(calls.at(-1), "POST /rest/v1/rpc/retain_deleted_account");
});

Deno.test("another member banned or on hold: that chat is kept and frozen, the others erased, the user pruned", async () => {
  channels = { "held-chat": [], "plain-chat": [] };
  const chats = { keep: [{ match: "held-chat", other: OTHER }], erase: ["plain-chat"] };
  assertEquals(await deleteAccount([false, false], chats), 204);
  assertEquals(calls.slice(0, 7), [
    "GET /auth/v1/user",
    "POST /rest/v1/rpc/retain_deleted_account",
    "POST /rest/v1/rpc/deleted_account_chats",
    `stream leave held-chat ${USER} ${OTHER}`,
    "stream freeze held-chat",
    "stream delete plain-chat",
    `stream pruning ${USER}`,
  ]);
  assertEquals(calls.includes(`stream hard ${USER}`), false);
  assertEquals(calls.at(-1), `DELETE /auth/v1/admin/users/${USER}`);
});

Deno.test("Stream's deletion failing in the background stops before the auth user", async () => {
  taskStatus = "failed";
  try {
    assertEquals(await deleteAccount([false, false]), 500);
  } finally {
    taskStatus = "completed";
  }
  assertEquals(calls.includes(`DELETE /auth/v1/admin/users/${USER}`), false);
});

Deno.test("the data-exports bucket: missing from a project is nothing to delete; failing stops the deletion", async () => {
  exportsBucket = "missing";
  try {
    assertEquals(await deleteAccount([false, false]), 204);
    assertEquals(calls.at(-1), `DELETE /auth/v1/admin/users/${USER}`);
    exportsBucket = "down";
    assertEquals(await deleteAccount([false, false]), 500);
    assertEquals(calls.includes(`DELETE /auth/v1/admin/users/${USER}`), false);
  } finally {
    exportsBucket = "ok";
  }
});
