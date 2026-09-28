// GET /app-config → { mediaUrl }. Public: what the app needs before anyone signs in, such as where
// media is served from (MEDIA_PUBLIC_URL). Media links themselves are signed by the backend (cards,
// media_urls); mediaUrl stays for apps that still build URLs from keys.
import { env } from "../_shared/env.ts";
import { json } from "../_shared/http.ts";

Deno.serve(() => json({ mediaUrl: env("MEDIA_PUBLIC_URL") }));
