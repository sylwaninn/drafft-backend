// POST /stream-token → { apiKey, userId, token }
// Called at launch and whenever the Stream client asks for a fresh token.
import { env } from "../_shared/env.ts";
import { json, serve } from "../_shared/http.ts";
import { ensureUsers, stream } from "../_shared/stream.ts";
import { requireUser } from "../_shared/supabase.ts";

serve(async (req) => {
  const user = await requireUser(req);
  await ensureUsers([user.id]);
  // 24 h: the Swift client refreshes through this function before expiry.
  const token = stream().createToken(user.id, Math.floor(Date.now() / 1000) + 24 * 60 * 60);
  return json({ apiKey: env("STREAM_API_KEY"), userId: user.id, token });
});
