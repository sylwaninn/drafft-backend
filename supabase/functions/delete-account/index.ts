// POST /delete-account → 204
//
// Two outcomes, decided by the database (retain_deleted_account, migrations/..._retained_account_deletion.sql):
// - Reported, held or banned (ever): the account is kept for members' safety, a soft delete. It disappears for
//   everyone at once and can't sign in again, but nothing is erased: not its chats (frozen by db-events), not
//   its media in R2 (private with the media work), not its selfies. All of it happens in that one transaction.
// - Anything else: erased. Chat history, media and selfies go first; deleting the auth user last cascades
//   through every table. If a step fails the account still exists, so the person can simply try again.
import { serve } from "../_shared/http.ts";
import { deleteObject, listKeys } from "../_shared/r2.ts";
import { stream } from "../_shared/stream.ts";
import { admin, must, requireUser } from "../_shared/supabase.ts";

/** The outside services the erasure touches. Replaced by the tests only. */
export const services = {
  deleteChatUser: (id: string) =>
    stream().deleteUsers([id], { user: "hard", messages: "hard", conversations: "hard" }).then(() => {}),
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

serve(async (req) => {
  const user = await requireUser(req);

  if (await retained(user.id)) return new Response(null, { status: 204 });

  try {
    await services.deleteChatUser(user.id);
  } catch (error) {
    // Unknown to Stream: never opened the chat. Anything else must stop the deletion.
    if (!String(error).includes("does not exist")) throw error;
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
