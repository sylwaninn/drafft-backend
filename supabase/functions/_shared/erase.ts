// Erasing what an account or a chat leaves outside the database (Stream, R2, the selfies bucket), for what the
// privacy policy keeps for a time only: accounts kept for safety, chats of ended matches (db-events
// `account.purge`, `chat.erase`). Every call is idempotent: something already gone counts as done.
import { deleteObject, listKeys } from "./r2.ts";
import { viaProvider } from "./providers.ts";
import { stream } from "./stream.ts";
import { admin } from "./supabase.ts";

/** Stream's answer for a channel or a user it doesn't know (never created, or deleted already). */
export function isGone(error: unknown): boolean {
  const status = (error as { status?: unknown } | null)?.status;
  return status === 404 || /does not exist|not found/i.test(String(error));
}

type Attachment = { type?: string; key?: unknown; poster_key?: unknown };
type Message = { id: string; attachments?: Attachment[] };

/** The objects a chat's messages point to: each drafft_media attachment's key and a video's poster, always a
 * chat object (`u/<id>/chat/…`, the only kind the app sends); anything else is left alone. */
export function chatMediaKeys(messages: Message[]): string[] {
  const keys = new Set<string>();
  for (const message of messages) {
    for (const attachment of message.attachments ?? []) {
      if (attachment.type !== "drafft_media") continue;
      for (const key of [attachment.key, attachment.poster_key]) {
        if (typeof key === "string" && /^u\/[0-9a-f-]{36}\/chat\/[A-Za-z0-9_.-]+$/.test(key) && !key.includes("..")) {
          keys.add(key);
        }
      }
    }
  }
  return [...keys];
}

const PAGE = 300;

/** Every message of a match's chat, or null when Stream has no such channel (nobody wrote, or erased). */
async function chatMessages(matchId: string): Promise<Message[] | null> {
  const channel = stream().channel("messaging", matchId);
  const all: Message[] = [];
  let before: string | undefined;
  for (;;) {
    let page: { messages?: Message[] };
    try {
      page = await viaProvider("stream", () =>
        channel.query({
          state: true,
          watch: false,
          presence: false,
          messages: { limit: PAGE, ...(before ? { id_lt: before } : {}) },
        })) as { messages?: Message[] };
    } catch (error) {
      if (isGone(error)) return all.length > 0 ? all : null;
      throw error;
    }
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

/** A chat, for good: the media its messages point to (either member's), then the channel with its messages. */
export async function eraseChat(matchId: string): Promise<void> {
  const messages = await chatMessages(matchId);
  if (messages === null) return;
  await deleteKeys(chatMediaKeys(messages));
  try {
    await viaProvider("stream", () => stream().channel("messaging", matchId).delete({ hard_delete: true }));
  } catch (error) {
    if (!isGone(error)) throw error;
  }
}

/** The Stream user, its messages and the conversations it is still a member of. */
export async function eraseChatUser(userId: string): Promise<void> {
  try {
    await viaProvider(
      "stream",
      () => stream().deleteUsers([userId], { user: "hard", messages: "hard", conversations: "hard" }),
    );
  } catch (error) {
    if (!isGone(error)) throw error;
  }
}

/** Every object under the account's prefix: photos, videos, voice intro, what it sent in chats. */
export async function eraseMedia(userId: string): Promise<void> {
  await deleteKeys(await listKeys(`u/${userId}/`));
}

/** The account's folder in the verification-selfies bucket. */
export async function eraseSelfies(userId: string): Promise<void> {
  const listed = await admin.storage.from("verification-selfies").list(userId, { limit: 1000 });
  if (listed.error) throw new Error(`list selfies of ${userId}: ${listed.error.message}`);
  if (listed.data.length === 0) return;
  const removed = await admin.storage.from("verification-selfies").remove(
    listed.data.map((f) => `${userId}/${f.name}`),
  );
  if (removed.error) throw new Error(`delete selfies of ${userId}: ${removed.error.message}`);
}
