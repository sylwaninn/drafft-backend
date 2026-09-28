// delete-account: an account the database keeps (reported, held, banned) is never erased; any other is.
//
//   cd supabase/functions && deno test --allow-env --allow-read=. _tests/
//
// No network: fetch answers Supabase (Auth, the RPC, Storage) from a script, and Stream and R2 are replaced
// through the function's `services`. Every call is recorded, in order.
import { assertEquals } from "jsr:@std/assert@1";

const ENV: Record<string, string> = {
  SUPABASE_URL: "http://supabase.test",
  SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
  SUPABASE_SECRET_KEYS: "",
  STREAM_API_KEY: "test-stream-key",
  STREAM_API_SECRET: "test-stream-secret",
};
for (const [name, value] of Object.entries(ENV)) Deno.env.set(name, value);

const USER = "11111111-1111-4111-8111-111111111111";
const calls: string[] = [];
/** What retain_deleted_account answers, call after call. */
let retainAnswers: boolean[] = [];
/** What deleted_account_chats answers. */
let chatsAnswer: { keep: { match: string; other: string }[]; erase: string[] } = { keep: [], erase: [] };

globalThis.fetch = async (input: Request | URL | string, init?: RequestInit): Promise<Response> => {
  const request = input instanceof Request ? input : new Request(String(input), init);
  const path = new URL(request.url).pathname;
  const call = `${request.method} ${path}`;
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
  if (call === "POST /storage/v1/object/list/verification-selfies") return Response.json([]);
  if (call === `DELETE /auth/v1/admin/users/${USER}`) return Response.json({});
  return Promise.reject(new Error(`unexpected fetch in a test: ${call}`));
};

type Handler = (req: Request) => Response | Promise<Response>;
let handler: Handler | undefined;
const serve = Deno.serve;
// deno-lint-ignore no-explicit-any
(Deno as any).serve = (h: Handler) => {
  handler = h;
  return { finished: Promise.resolve(), shutdown: () => Promise.resolve(), ref() {}, unref() {} };
};
const { services } = await import("../delete-account/index.ts");
Deno.serve = serve;

services.deleteChatUser = (id) => (calls.push(`stream deleteUsers ${id}`), Promise.resolve());
services.pruneChatUser = (id) => (calls.push(`stream prune ${id}`), Promise.resolve());
services.freezeChat = (id, chat) => (calls.push(`stream freeze ${chat.match} ${id} ${chat.other}`), Promise.resolve());
services.deleteChat = (match) =>
  match === "never-written"
    ? Promise.reject(new Error("channel does not exist"))
    : (calls.push(`stream delete ${match}`), Promise.resolve());
services.listMedia = (prefix) => (calls.push(`r2 list ${prefix}`), Promise.resolve([`${prefix}photo.jpg`]));
services.deleteMedia = (key) => (calls.push(`r2 delete ${key}`), Promise.resolve());

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

Deno.test("any other account: chat, media, selfies and the auth user erased, in that order", async () => {
  assertEquals(await deleteAccount([false, false]), 204);
  assertEquals(calls, [
    "GET /auth/v1/user",
    "POST /rest/v1/rpc/retain_deleted_account",
    "POST /rest/v1/rpc/deleted_account_chats",
    `stream deleteUsers ${USER}`,
    `r2 list u/${USER}/`,
    `r2 delete u/${USER}/photo.jpg`,
    "POST /storage/v1/object/list/verification-selfies",
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
  const chats = {
    keep: [{ match: "held-chat", other: "22222222-2222-4222-8222-222222222222" }],
    erase: ["plain-chat", "never-written"],
  };
  assertEquals(await deleteAccount([false, false], chats), 204);
  assertEquals(calls.slice(0, 6), [
    "GET /auth/v1/user",
    "POST /rest/v1/rpc/retain_deleted_account",
    "POST /rest/v1/rpc/deleted_account_chats",
    `stream freeze held-chat ${USER} 22222222-2222-4222-8222-222222222222`,
    "stream delete plain-chat",
    `stream prune ${USER}`,
  ]);
  assertEquals(calls.includes(`stream deleteUsers ${USER}`), false);
  assertEquals(calls.at(-1), `DELETE /auth/v1/admin/users/${USER}`);
});
