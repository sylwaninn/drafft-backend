// Stream Chat, server side. The app uses the low-level StreamChat Swift client with drafft's own UI.
// One `messaging` channel per match, with the match id as channel id.
import { StreamChat } from "npm:stream-chat@9";
import { env } from "./env.ts";
import { admin, must } from "./supabase.ts";
import { viaProvider } from "./providers.ts";
import { language, messageSent, someone } from "./texts.ts";

let client: StreamChat | undefined;

/** Created on first use, so handlers that don't touch chat run without Stream credentials. */
export function stream(): StreamChat {
  client ??= StreamChat.getInstance(env("STREAM_API_KEY"), env("STREAM_API_SECRET"));
  return client;
}

/** Tests only: a stand-in for the Stream client. */
export function useStreamClientForTests(fake: unknown) {
  client = fake as StreamChat;
}

/**
 * Creates the match channel if needed (idempotent), and returns it. Null when the match has ended (unmatch,
 * block) or is gone (a deleted account): events are retried and arrive out of order, so a late
 * `match.created` or `session.*` must not reopen a channel that `match.ended` froze. The match is read
 * here, at delivery, never taken from the payload.
 */
export async function ensureChannel(matchId: string) {
  const { data: match, error } = await admin.from("matches").select("user_a, user_b, ended_at").eq("id", matchId)
    .maybeSingle();
  // An error is not "gone": throw, and the outbox retries.
  if (error) throw new Error(`match ${matchId}: ${error.message}`);
  if (!match || match.ended_at) return null;
  await ensureUsers([match.user_a, match.user_b]);
  const channel = stream().channel("messaging", matchId, {
    members: [match.user_a, match.user_b],
    created_by_id: match.user_a,
  });
  await viaProvider("stream", () => channel.create());
  return { channel, members: [match.user_a, match.user_b] as string[] };
}

/**
 * A person's Stream user. Stream sends message pushes itself, from the template in scripts/stream-push.ts:
 * the sender's name is the title, and the recipient's user carries, in their app language, the body without
 * the text (`drafft_push.message`) and the title for a sender without a name (`drafft_push.someone`), plus
 * whether message previews are on (`notify_message_previews`, off by default: no text in the push). An upsert
 * replaces the whole user, so every upsert writes all of it.
 */
export function streamUser(
  p: { id: string; name: string | null; language: unknown; notify_message_previews: boolean },
) {
  const lang = language(p.language);
  return {
    id: p.id,
    name: p.name ?? "",
    language: lang,
    drafft_push: {
      message: messageSent[lang],
      someone: someone[lang],
      previews: p.notify_message_previews === true,
    },
  };
}

/**
 * Stream needs the users to exist before they join a channel. Also called when a name, the app language or
 * the previews setting changes (db-events `stream.user`), so pushes follow at once.
 */
export async function ensureUsers(ids: string[]) {
  const profiles = must(
    await admin.from("profiles").select("id, name, language, notify_message_previews").in("id", ids),
    "profiles",
  );
  if (profiles.length === 0) return;
  await viaProvider("stream", () => stream().upsertUsers(profiles.map(streamUser)));
}

/** Server-side author of moderation actions (bans). Never gets a token: stream-token signs profile ids only. */
const SYSTEM_USER = "drafft";

/**
 * An account on hold (`profiles.moderation` set by the team) reads its chats but can't write in them
 * (messages, reactions, uploads): a global Stream ban while held, lifted when the hold is. A voluntary
 * pause doesn't ban: chats stay writable. Both calls are idempotent.
 */
export async function setChatHeld(userId: string, held: boolean) {
  await ensureUsers([userId]);
  await viaProvider("stream", async () => {
    if (held) {
      await stream().upsertUser({ id: SYSTEM_USER, name: "drafft", role: "admin" });
      await stream().banUser(userId, { banned_by_id: SYSTEM_USER, reason: "hold" });
    } else {
      await stream().unbanUser(userId);
    }
  });
}

/**
 * Sends a message with a deterministic id, so a retried event doesn't post twice.
 * Stream answers a duplicate id with an error, which is treated as success here.
 * Without Stream's push: every server message (openers, super like notes, sessions) comes with its own
 * push from db-events, in the person's language and under their settings.
 */
export async function sendOnce(
  channel: ReturnType<StreamChat["channel"]>,
  message: { id: string; user_id: string; text: string; drafft?: Record<string, unknown> },
) {
  try {
    await viaProvider(
      "stream",
      () => channel.sendMessage(message as Parameters<typeof channel.sendMessage>[0], { skip_push: true }),
    );
  } catch (error) {
    if (String(error).includes("already exists")) return;
    throw error;
  }
}

/** A Stream message as the server reads it back. */
export type StreamMessage = {
  id: string;
  text?: string;
  type?: string;
  user?: { id?: string };
  created_at?: string;
  updated_at?: string;
  deleted_at?: string;
  quoted_message_id?: string;
  attachments?: Record<string, unknown>[];
};

/** Every message of a match's chat, oldest first; none when Stream has no such channel (nobody wrote yet, or
 * erased). Read with the secret: an ended match's frozen channel too. */
export async function channelMessages(matchId: string): Promise<StreamMessage[]> {
  const page = 300;
  const channel = stream().channel("messaging", matchId);
  let all: StreamMessage[] = [];
  let before: string | undefined;
  for (;;) {
    let messages: StreamMessage[];
    try {
      const res = await viaProvider("stream", () =>
        channel.query({
          state: true,
          watch: false,
          presence: false,
          messages: { limit: page, ...(before ? { id_lt: before } : {}) },
        }));
      messages = (res.messages ?? []) as unknown as StreamMessage[];
    } catch (error) {
      const status = (error as { status?: unknown } | null)?.status;
      if (status === 404 || /does not exist|not found/i.test(String(error))) return all;
      throw error;
    }
    all = [...messages, ...all];
    if (messages.length < page) return all;
    before = messages[0].id;
  }
}
