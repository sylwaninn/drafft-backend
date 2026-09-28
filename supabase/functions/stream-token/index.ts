// POST /stream-token → { apiKey, userId, token }
// Called at launch and whenever the Stream client asks for a fresh token.
import { env } from "../_shared/env.ts";
import { json, serve } from "../_shared/http.ts";
import { ensureUsers, setChatHeld, stream } from "../_shared/stream.ts";
import { admin, requireUser } from "../_shared/supabase.ts";

serve(async (req) => {
  const user = await requireUser(req);
  const { data, error } = await admin.from("profiles").select("moderation").eq("id", user.id).maybeSingle();
  if (error) throw new Error(`profile ${user.id}: ${error.message}`);
  // On hold: the ban is normally set by db-events (account.moderation); set again here so a lost event
  // can't leave a held person able to write. A voluntary pause doesn't ban: chats stay writable.
  if (data?.moderation) await setChatHeld(user.id, true);
  else await ensureUsers([user.id]);
  // 24 h: the Swift client refreshes through this function before expiry.
  const token = stream().createToken(user.id, Math.floor(Date.now() / 1000) + 24 * 60 * 60);
  return json({ apiKey: env("STREAM_API_KEY"), userId: user.id, token });
});
