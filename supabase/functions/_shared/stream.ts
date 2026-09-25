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

/** Creates the match channel if needed (idempotent), and returns it. */
export async function ensureChannel(matchId: string) {
  const match = must(
    await admin.from("matches").select("user_a, user_b").eq("id", matchId).single(),
    `match ${matchId}`,
  );
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
