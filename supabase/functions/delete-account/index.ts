// POST /delete-account → 204
//
// Deletes the caller's account (_shared/erase.ts, deleteAccount). Banned, held or under an open report: kept for
// members' safety (a soft delete, at once) and erased a year after its case is closed (db-events
// `account.purge`). Anything else: erased now, with its chats, media and selfies; a chat kept for the team
// (decision 5.4) is erased a year later (`chat.erase`). If a step fails the account still exists, so the person
// can simply try again.
import { deleteAccount } from "../_shared/erase.ts";
import { serve } from "../_shared/http.ts";
import { requireUser } from "../_shared/supabase.ts";

serve(async (req) => {
  const user = await requireUser(req);
  await deleteAccount(user.id);
  return new Response(null, { status: 204 });
});
