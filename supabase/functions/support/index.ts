// POST /support { topic, message, language, email?, context?, turnstileToken? } → { reference }
// Every "Get help" and "Contact us" form in the app. Signed in, the reply goes to the account's email;
// signed out (a sign-up or a reset that got stuck), to the email typed in the form. The request is stored
// (private.support_requests, for the dashboard), then db-events emails the person their reference and the
// team a copy. The acknowledgement is a fixed text with the reference, never what was typed.
// Signed out, the body carries a Cloudflare Turnstile token (_shared/turnstile.ts).
// Limits (create_support_request): 5 an hour per account; signed out, 3 an hour and 5 a day per address and
// 200 an hour in all.
import { HttpError, json, readJson, serve } from "../_shared/http.ts";
import { admin } from "../_shared/supabase.ts";
import { env, optionalEnv } from "../_shared/env.ts";
import { verifySignedOutCaptcha } from "../_shared/turnstile.ts";

interface Body {
  topic?: unknown;
  message?: unknown;
  language?: unknown;
  email?: unknown;
  context?: unknown;
  turnstileToken?: unknown;
}

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

serve(async (req) => {
  const body = await readJson<Body>(req);
  const topic = typeof body.topic === "string" ? body.topic.trim() : "";
  const message = typeof body.message === "string" ? body.message.trim() : "";
  if (!topic || topic.length > 80) throw new HttpError(400, "invalid_topic");
  if (!message || message.length > 4000) throw new HttpError(400, "invalid_message");

  // Signed in: the account's own email, whatever the form says.
  let userId: string | null = null;
  let email = typeof body.email === "string" ? body.email.trim() : "";
  const jwt = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (jwt) {
    const { data } = await admin.auth.getUser(jwt);
    if (data.user) {
      userId = data.user.id;
      email = data.user.email ?? email;
    }
  }
  await verifySignedOutCaptcha(req, userId, body.turnstileToken, {
    secret: optionalEnv("TURNSTILE_SECRET_KEY"),
    supabaseUrl: env("SUPABASE_URL"),
  });
  if (!emailPattern.test(email) || email.length > 320) throw new HttpError(400, "invalid_email");

  const context = body.context && typeof body.context === "object" ? body.context : {};
  const { data, error } = await admin.rpc("create_support_request", {
    p_user: userId,
    p_email: email,
    p_language: typeof body.language === "string" ? body.language : "en",
    p_topic: topic,
    p_message: message,
    p_context: context,
  });
  if (error) {
    if (error.hint === "too_many_requests") throw new HttpError(429, "too_many_requests");
    throw new Error(`support request: ${error.message}`);
  }
  return json({ reference: data });
});
