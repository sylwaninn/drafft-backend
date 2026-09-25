// GET /app-config → { mediaUrl }. Public: what the app needs before anyone signs in, such as where
// media is served from (MEDIA_PUBLIC_URL), so it can turn stored keys into URLs.
import { env } from "../_shared/env.ts";
import { json } from "../_shared/http.ts";

Deno.serve(() => json({ mediaUrl: env("MEDIA_PUBLIC_URL") }));
