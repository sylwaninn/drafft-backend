// Stream Chat, server side. The app uses the low-level StreamChat Swift client with drafft's own UI.
// One `messaging` channel per match, with the match id as channel id.
import { StreamChat } from "npm:stream-chat@9";
import { env } from "./env.ts";
import { admin, must } from "./supabase.ts";

let client: StreamChat | undefined;

/** Created on first use, so handlers that don't touch chat run without Stream credentials. */
export function stream(): StreamChat {
  client ??= StreamChat.getInstance(env("STREAM_API_KEY"), env("STREAM_API_SECRET"));
  return client;
}

/**
 * Creates the match channel if needed (idempotent), and returns it. Null when the match has ended (unmatch,
 * block) or is gone (a deleted account): events are retried and arrive out of order, so a late
 * `match.created` or `session.*` must not bring back a channel that `match.ended` deleted. The match is read
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
  await channel.create();
  return { channel, members: [match.user_a, match.user_b] as string[] };
}

/** Stream needs the users to exist before they join a channel. */
export async function ensureUsers(ids: string[]) {
  const profiles = must(await admin.from("profiles").select("id, name").in("id", ids), "profiles");
  await stream().upsertUsers(profiles.map((p) => ({ id: p.id, name: p.name })));
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
  if (held) {
    await stream().upsertUser({ id: SYSTEM_USER, name: "drafft", role: "admin" });
    await stream().banUser(userId, { banned_by_id: SYSTEM_USER, reason: "hold" });
  } else {
    await stream().unbanUser(userId);
  }
}

/**
 * Sends a message with a deterministic id, so a retried event doesn't post twice.
 * Stream answers a duplicate id with an error, which is treated as success here.
 */
export async function sendOnce(
  channel: ReturnType<StreamChat["channel"]>,
  message: { id: string; user_id: string; text: string; drafft?: Record<string, unknown> },
) {
  try {
    await channel.sendMessage(message as Parameters<typeof channel.sendMessage>[0]);
  } catch (error) {
    if (String(error).includes("already exists")) return;
    throw error;
  }
}
