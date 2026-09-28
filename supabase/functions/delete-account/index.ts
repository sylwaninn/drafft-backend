// POST /delete-account → 204
//
// Two outcomes, decided by the database (retain_deleted_account, migrations/..._retained_account_deletion.sql):
// - Banned, held or under an open report: the account is kept for members' safety, a soft delete. It disappears for
//   everyone at once and can't sign in again, but nothing is erased: not its chats (frozen by db-events), not
//   its media in R2 (private with the media work), not its selfies. All of it happens in that one transaction.
// - Anything else: erased. Chat history, media and selfies go first; deleting the auth user last cascades
//   through every table. If a step fails the account still exists, so the person can simply try again.
//   One exception (decision 5.4): a conversation whose other member is banned or on hold at that moment keeps
//   its messages, for the team. It is frozen and both members leave it, like an ended match; the Stream user
//   is pruned (its name and data cleared) instead of hard deleted, so those messages stay.
import { serve } from "../_shared/http.ts";
import { deleteObject, listKeys } from "../_shared/r2.ts";
import { stream } from "../_shared/stream.ts";
import { admin, must, requireUser } from "../_shared/supabase.ts";

/** A conversation kept because its other member is banned or on hold. */
export interface KeptChat {
  match: string;
  other: string;
}

/** The outside services the erasure touches. Replaced by the tests only. */
export const services = {
  deleteChatUser: (id: string) =>
    stream().deleteUsers([id], { user: "hard", messages: "hard", conversations: "hard" }).then(() => {}),
  pruneChatUser: (id: string) => stream().deleteUsers([id], { user: "pruning" }).then(() => {}),
  freezeChat: async (id: string, chat: KeptChat) => {
    const channel = stream().channel("messaging", chat.match);
    await channel.removeMembers([id, chat.other]);
    await channel.updatePartial({ set: { frozen: true } });
  },
  deleteChat: (match: string) => stream().channel("messaging", match).delete({ hard_delete: true }).then(() => {}),
  listMedia: (prefix: string) => listKeys(prefix),
  deleteMedia: (key: string) => deleteObject(key),
};

/** Keeps the account when it must be (and answers true), else changes nothing (false). Idempotent. */
async function retained(userId: string): Promise<boolean> {
  const result = must(await admin.rpc("retain_deleted_account", { p_user: userId }), "retain") as {
    retained?: boolean;
  };
  return result.retained === true;
}

/** Unknown to Stream (never opened the chat, no message yet): nothing to do. Anything else stops the deletion. */
async function ignoringUnknown(call: () => Promise<void>) {
  try {
    await call();
  } catch (error) {
    if (!String(error).includes("does not exist")) throw error;
  }
}

serve(async (req) => {
  const user = await requireUser(req);

  if (await retained(user.id)) return new Response(null, { status: 204 });

  const chats = must(await admin.rpc("deleted_account_chats", { p_user: user.id }), "chats") as {
    keep: KeptChat[];
    erase: string[];
  };
  if (chats.keep.length === 0) {
    await ignoringUnknown(() => services.deleteChatUser(user.id));
  } else {
    for (const chat of chats.keep) await ignoringUnknown(() => services.freezeChat(user.id, chat));
    for (const match of chats.erase) await ignoringUnknown(() => services.deleteChat(match));
    await ignoringUnknown(() => services.pruneChatUser(user.id));
  }

  const keys = await services.listMedia(`u/${user.id}/`);
  for (let i = 0; i < keys.length; i += 20) {
    await Promise.all(keys.slice(i, i + 20).map(services.deleteMedia));
  }

  // Identity-check selfies (a private bucket, not R2).
  const selfies = await admin.storage.from("verification-selfies").list(user.id, { limit: 1000 });
  if (selfies.error) throw new Error(`list selfies: ${selfies.error.message}`);
  if (selfies.data.length > 0) {
    const removed = await admin.storage.from("verification-selfies")
      .remove(selfies.data.map((f) => `${user.id}/${f.name}`));
    if (removed.error) throw new Error(`delete selfies: ${removed.error.message}`);
  }

  // Reported or held while the above ran: keep what is left (the database rows) instead of erasing it.
  if (await retained(user.id)) return new Response(null, { status: 204 });

  const { error } = await admin.auth.admin.deleteUser(user.id);
  if (error) throw new Error(`delete auth user: ${error.message}`);
  return new Response(null, { status: 204 });
});
