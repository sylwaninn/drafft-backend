// Erasing, outside the database too (Stream, R2, the selfies bucket), one implementation for every way in:
// delete-account (the member), and db-events `account.purge` (an account kept for safety, a year after its
// case closed), `chat.erase` (a chat, a year after it ended), `selfie.delete` and `selfie.expired`.
// Every step is idempotent: something already gone counts as done, and only a clear "gone" does (HTTP 404, or
// Stream's code 16); any other failure throws, and the caller retries.
import { deleteObject, listKeys } from "./r2.ts";
import { viaProvider } from "./providers.ts";
import { stream } from "./stream.ts";
import { admin, check, must } from "./supabase.ts";

/** Stream (or R2) doesn't have it: never created, or deleted already. */
export function isGone(error: unknown): boolean {
  const e = error as { status?: unknown; code?: unknown } | null;
  return e?.status === 404 || e?.code === 16;
}

/** A Stream call on something that may be gone already. */
export async function unlessGone(call: () => Promise<unknown>): Promise<void> {
  try {
    await viaProvider("stream", call);
  } catch (error) {
    if (!isGone(error)) throw error;
  }
}

/** Waits between two looks at a Stream task. Replaced by the tests only. */
export const timing = { sleep: (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)) };

// About a minute in all, within an Edge Function's time.
const TASK_WAITS = [500, 1000, 2000, 4000, 8000, 10000, 10000, 10000, 10000];

/**
 * Stream deletes users in the background: `deleteUsers` answers with a task, done only once the task says
 * `completed`. A failed task throws; one still running after a minute throws too, and the retry starts the
 * deletion again (deleting twice is harmless).
 */
async function streamTask(what: string, start: () => Promise<unknown>): Promise<void> {
  const started = await viaProvider("stream", start) as { task_id?: unknown };
  if (typeof started?.task_id !== "string") throw new Error(`${what}: Stream answered without a task`);
  const id = started.task_id;
  for (const wait of TASK_WAITS) {
    await timing.sleep(wait);
    const task = await viaProvider("stream", () => stream().getTask(id)) as { status?: string; error?: unknown };
    if (task.status === "completed") return;
    if (task.status === "failed") {
      throw new Error(`${what}: Stream task ${id} failed: ${JSON.stringify(task.error ?? null).slice(0, 300)}`);
    }
  }
  throw new Error(`${what}: Stream task ${id} still running`);
}

type Attachment = { type?: string; key?: unknown; poster_key?: unknown };
/** `user` is the sender, set by Stream; the attachments are whatever the sender's app wrote. */
export type Message = { id: string; user?: { id?: unknown }; attachments?: Attachment[] };

/**
 * The objects a chat's messages point to: each drafft_media attachment's key and a video's poster, only when it
 * is a chat object of the message's own sender (`u/<sender>/chat/<name>`). An attachment naming anything else (a
 * profile photo, someone else's object) is left alone: attachments are written by the app, not trusted.
 */
export function chatMediaKeys(messages: Message[]): string[] {
  const keys = new Set<string>();
  for (const message of messages) {
    const sender = typeof message.user?.id === "string" ? message.user.id.toLowerCase() : "";
    if (!/^[0-9a-f-]{36}$/.test(sender)) continue;
    const own = new RegExp(`^u/${sender}/chat/[A-Za-z0-9_-][A-Za-z0-9_.-]*$`);
    for (const attachment of message.attachments ?? []) {
      if (attachment.type !== "drafft_media") continue;
      for (const key of [attachment.key, attachment.poster_key]) {
        if (typeof key === "string" && own.test(key) && !key.includes("..")) keys.add(key);
      }
    }
  }
  return [...keys];
}

const PAGE = 300;

/**
 * Every message of a match's chat, or null when Stream has no such channel (nobody wrote, or erased already).
 * Asked first with a search, which never creates anything: `channel.query` on a channel Stream doesn't have
 * would try to create it, and fail.
 */
async function chatMessages(matchId: string): Promise<Message[] | null> {
  const found = await viaProvider(
    "stream",
    () =>
      stream().queryChannelsRequest({ type: "messaging", id: { $eq: matchId } }, [], {
        limit: 1,
        message_limit: 0,
        state: false,
        watch: false,
        presence: false,
      }),
  );
  if (found.length === 0) return null;
  const channel = stream().channel("messaging", matchId);
  const all: Message[] = [];
  let before: string | undefined;
  for (;;) {
    const page = await viaProvider("stream", () =>
      channel.query({
        state: true,
        watch: false,
        presence: false,
        messages: { limit: PAGE, ...(before ? { id_lt: before } : {}) },
      })) as { messages?: Message[] };
    const messages = page.messages ?? [];
    all.push(...messages);
    // Oldest first: the next page is before the first one.
    if (messages.length < PAGE) return all;
    before = messages[0].id;
  }
}

/** Deletes objects 20 at a time. */
async function deleteKeys(keys: string[]) {
  for (let i = 0; i < keys.length; i += 20) await Promise.all(keys.slice(i, i + 20).map(deleteObject));
}

/** A chat, for good: the media its messages point to (each sender's own), then the channel with its messages. */
export async function eraseChat(matchId: string): Promise<void> {
  const messages = await chatMessages(matchId);
  if (messages === null) return;
  await deleteKeys(chatMediaKeys(messages));
  await unlessGone(() => stream().channel("messaging", matchId).delete({ hard_delete: true }));
}

/** A chat kept for the team (decision 5.4): both members leave it, and nobody can write in it. */
export async function freezeChat(matchId: string, members: string[]): Promise<void> {
  const channel = stream().channel("messaging", matchId);
  await unlessGone(async () => {
    await channel.removeMembers(members);
    await channel.updatePartial({ set: { frozen: true } });
  });
}

/** The Stream user, its messages and the conversations it is still a member of. */
export async function eraseChatUser(userId: string): Promise<void> {
  await streamTask(
    `erase Stream user ${userId}`,
    () => stream().deleteUsers([userId], { user: "hard", messages: "hard", conversations: "hard" }),
  );
}

/** The Stream user's name and data only: its messages stay, in a chat kept for the team. */
export async function pruneChatUser(userId: string): Promise<void> {
  await streamTask(`prune Stream user ${userId}`, () => stream().deleteUsers([userId], { user: "pruning" }));
}

/** Every object under the account's prefix: photos, videos, voice intro, what it sent in chats. */
export async function eraseMedia(userId: string): Promise<void> {
  await deleteKeys(await listKeys(`u/${userId}/`));
}

/** Every file of the account's folder in a private Storage bucket, page after page. */
export async function emptyFolder(bucket: string, userId: string): Promise<void> {
  for (;;) {
    const listed = await admin.storage.from(bucket).list(userId, { limit: 1000 });
    if (listed.error) throw new Error(`list ${bucket} of ${userId}: ${listed.error.message}`);
    if (listed.data.length === 0) return;
    const removed = await admin.storage.from(bucket).remove(listed.data.map((f) => `${userId}/${f.name}`));
    if (removed.error) throw new Error(`delete ${bucket} of ${userId}: ${removed.error.message}`);
    if (listed.data.length < 1000) return;
  }
}

/** The account's verification selfies, whatever they were sent for, then their records. */
export async function eraseSelfies(userId: string): Promise<void> {
  await emptyFolder("verification-selfies", userId);
  check(await admin.rpc("forget_selfies", { p_user: userId }), "forget selfies");
}

/** Keeps the account when it must be (and answers true), else changes nothing (false). Idempotent. */
async function retained(userId: string): Promise<boolean> {
  const result = must(await admin.rpc("retain_deleted_account", { p_user: userId }), "retain") as {
    retained?: boolean;
  };
  return result.retained === true;
}

export type Deletion = "kept" | "erased";

/**
 * Deleting an account (delete-account). The database decides (retain_deleted_account):
 * - banned, held or under an open report: kept for members' safety, a soft delete, all in that one
 *   transaction; db-events `account.purge` erases it a year after its case is closed;
 * - anything else: erased. Its chats with their media, its Stream user, its media and selfies go first;
 *   deleting the Auth user last cascades through every table. A step that fails leaves the account in place,
 *   so the deletion can run again. One exception (decision 5.4): a chat whose other member is banned or on
 *   hold at that moment is kept for the team, frozen, and erased a year later (`chat.erase`); the Stream user
 *   is then pruned instead of deleted, so its messages there stay.
 */
export async function deleteAccount(userId: string): Promise<Deletion> {
  if (await retained(userId)) return "kept";

  const chats = must(await admin.rpc("deleted_account_chats", { p_user: userId }), "chats") as {
    keep: { match: string; other: string }[];
    erase: string[];
  };
  for (const chat of chats.keep) await freezeChat(chat.match, [userId, chat.other]);
  for (const match of chats.erase) await eraseChat(match);
  if (chats.keep.length === 0) await eraseChatUser(userId);
  else await pruneChatUser(userId);

  await eraseMedia(userId);
  await eraseSelfies(userId);

  // Reported or held while the above ran: keep what is left (the database rows) instead of erasing it.
  if (await retained(userId)) return "kept";

  const { error } = await admin.auth.admin.deleteUser(userId);
  // Gone already: an earlier run got this far.
  if (error && error.status !== 404) throw new Error(`delete auth user ${userId}: ${error.message}`);
  return "erased";
}
