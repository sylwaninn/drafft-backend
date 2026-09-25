// POST /chat-media { key, posterKey? } → { flagged }
//
// Silent check of a photo or video sent in a chat (its poster frame for a video), with the same
// Rekognition labels as profile photos. Nothing changes for either person: a flagged one is only
// recorded in media_flags, for actions (someone flagged too often) and metrics.
import { HttpError, json, readJson, serve } from "../_shared/http.ts";
import { moderateImage, moderationConfigured } from "../_shared/moderation.ts";
import { getObject } from "../_shared/r2.ts";
import { admin, check, requireUser } from "../_shared/supabase.ts";

interface Body {
  key: string;
  posterKey?: string;
}

serve(async (req) => {
  const user = await requireUser(req);
  const { key, posterKey } = await readJson<Body>(req);
  const prefix = `u/${user.id}/chat/`;
  if (!key?.startsWith(prefix) || (posterKey && !posterKey.startsWith(`u/${user.id}/`))) {
    throw new HttpError(403, "not_your_media");
  }
  if (!moderationConfigured()) return json({ flagged: false, checked: false });

  const bytes = await getObject(posterKey ?? key);
  if (!bytes) throw new HttpError(404, "media_not_found");
  // Over Rekognition's 5 MB: can't be checked, delivered as is (the app compresses well below).
  if (bytes.length > 5 * 1024 * 1024) return json({ flagged: false, checked: false });

  const { verdict, labels } = await moderateImage(bytes);
  const flagged = verdict !== "approved";
  if (flagged) {
    check(
      await admin.from("media_flags").insert({ user_id: user.id, context: "chat", key, verdict, labels }),
      "media flag",
    );
  }
  console.log(`chat-media: ${key} ${flagged ? verdict : "clean"} ${labels.join(", ")}`);
  return json({ flagged, checked: true });
});
