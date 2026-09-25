// POST /delete-account → 204
// Chat history and media go first; deleting the auth user last cascades through every table.
// If a step fails the account still exists, so the person can simply try again.
import { serve } from "../_shared/http.ts";
import { deleteObject, listKeys } from "../_shared/r2.ts";
import { stream } from "../_shared/stream.ts";
import { admin, requireUser } from "../_shared/supabase.ts";

serve(async (req) => {
  const user = await requireUser(req);

  try {
    await stream().deleteUsers([user.id], { user: "hard", messages: "hard", conversations: "hard" });
  } catch (error) {
    // Unknown to Stream: never opened the chat. Anything else must stop the deletion.
    if (!String(error).includes("does not exist")) throw error;
  }

  const keys = await listKeys(`u/${user.id}/`);
  for (let i = 0; i < keys.length; i += 20) {
    await Promise.all(keys.slice(i, i + 20).map(deleteObject));
  }

  const { error } = await admin.auth.admin.deleteUser(user.id);
  if (error) throw new Error(`delete auth user: ${error.message}`);
  return new Response(null, { status: 204 });
});
