// POST /media-upload-url { purpose, contentType, byteSize }
//   → { key, uploadUrl, headers, url, publicUrl, expiresIn }
//
// The app compresses on device first (photos resized, video to 720p MP4, voice to AAC), then PUTs the
// bytes straight to R2 with a background URLSession. Nothing goes through this server but the URL.
// Profile media is then registered with the add_profile_media RPC, which queues moderation.
import { HttpError, json, readJson, serve } from "../_shared/http.ts";
import { signedMediaUrl } from "../_shared/media_url.ts";
import { presignPut } from "../_shared/r2.ts";
import { admin, requireUser } from "../_shared/supabase.ts";

const MB = 1024 * 1024;
const images = { "image/jpeg": "jpg", "image/heic": "heic", "image/png": "png" };
const videos = { "video/mp4": "mp4", "video/quicktime": "mov" };
const audio = { "audio/mp4": "m4a", "audio/aac": "aac" };

const purposes: Record<string, { folder: string; types: Record<string, string>; maxBytes: number }> = {
  profile_photo: { folder: "photos", types: images, maxBytes: 15 * MB },
  profile_video: { folder: "videos", types: videos, maxBytes: 40 * MB },
  video_poster: { folder: "posters", types: images, maxBytes: 5 * MB },
  voice_intro: { folder: "voice", types: audio, maxBytes: 5 * MB },
  chat_photo: { folder: "chat", types: images, maxBytes: 15 * MB },
  chat_video: { folder: "chat", types: videos, maxBytes: 100 * MB },
  chat_voice: { folder: "chat", types: audio, maxBytes: 10 * MB },
  chat_file: {
    folder: "chat",
    types: { ...images, ...videos, ...audio, "application/pdf": "pdf", "application/octet-stream": "bin" },
    maxBytes: 100 * MB,
  },
};

interface Body {
  purpose: string;
  contentType: string;
  byteSize: number;
}

serve(async (req) => {
  const user = await requireUser(req);
  const { purpose, contentType, byteSize } = await readJson<Body>(req);

  const rule = purposes[purpose];
  if (!rule) throw new HttpError(400, "invalid_purpose");
  const ext = rule.types[contentType];
  if (!ext) throw new HttpError(400, "unsupported_type");
  if (!Number.isInteger(byteSize) || byteSize <= 0) throw new HttpError(400, "invalid_size");
  if (byteSize > rule.maxBytes) throw new HttpError(413, "too_large", `Up to ${rule.maxBytes / MB} MB`);
  // An account on hold can't write in chats (Stream ban), so no chat uploads either. A voluntary pause
  // keeps chats writable, uploads included. Profile media stays open.
  if (purpose.startsWith("chat_")) {
    const { data, error } = await admin.from("profiles").select("moderation").eq("id", user.id).maybeSingle();
    if (error) throw new Error(`profile ${user.id}: ${error.message}`);
    if (data?.moderation) throw new HttpError(403, "moderated");
  }

  const key = `u/${user.id}/${rule.folder}/${crypto.randomUUID()}.${ext}`;
  const expiresIn = 600;
  const uploadUrl = await presignPut(key, contentType, byteSize, expiresIn);
  // The uploader's own link to the object (the bucket is private: signed, about an hour).
  const url = await signedMediaUrl(key);

  return json({
    key,
    uploadUrl,
    headers: { "content-type": contentType, "content-length": String(byteSize) },
    url,
    // Same as url, for apps from before the bucket went private.
    publicUrl: url,
    expiresIn,
  });
});
