// Cloudflare Turnstile, server side: the support form sent signed out carries a Turnstile token, checked
// here against Siteverify before anything is stored. Signed in, the account is proof enough.
import { HttpError } from "./http.ts";

export const siteverifyUrl = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
export const expectedHostname = "getdrafft.com";

export interface TurnstileOptions {
  /** TURNSTILE_SECRET_KEY; undefined when the secret isn't set. */
  secret: string | undefined;
  /** SUPABASE_URL: https means a hosted project, where a missing secret is an error. */
  supabaseUrl: string;
  fetch?: typeof fetch;
}

/** The caller's IP, as the platform forwards it, when there is one. */
export function requestIp(req: Request): string | undefined {
  const forwarded = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0];
  return forwarded?.trim() || undefined;
}

/** Throws unless `token` is a Turnstile token Cloudflare accepts for getdrafft.com. */
export async function verifyTurnstile(req: Request, token: unknown, options: TurnstileOptions): Promise<void> {
  if (!options.secret) {
    if (options.supabaseUrl.startsWith("https://")) {
      console.error("support: TURNSTILE_SECRET_KEY is not set, signed-out requests are refused");
      throw new HttpError(500, "captcha_not_configured");
    }
    console.warn("support: TURNSTILE_SECRET_KEY is not set, captcha skipped (local only)");
    return;
  }
  if (typeof token !== "string" || !token || token.length > 2048) throw new HttpError(400, "captcha_required");

  const form = new URLSearchParams({ secret: options.secret, response: token, idempotency_key: crypto.randomUUID() });
  const ip = requestIp(req);
  if (ip) form.set("remoteip", ip);

  let outcome: { success?: unknown; hostname?: unknown; "error-codes"?: unknown };
  try {
    const response = await (options.fetch ?? fetch)(siteverifyUrl, { method: "POST", body: form });
    outcome = await response.json();
  } catch (error) {
    console.error("support: siteverify unreachable", error);
    throw new HttpError(403, "captcha_failed");
  }
  if (outcome.success !== true) {
    console.warn("support: captcha refused", outcome["error-codes"]);
    throw new HttpError(403, "captcha_failed");
  }
  if (outcome.hostname !== undefined && outcome.hostname !== expectedHostname) {
    console.warn("support: captcha from another hostname", outcome.hostname);
    throw new HttpError(403, "captcha_failed");
  }
}

/** The support form's rule: signed in, nothing to check; signed out, a valid Turnstile token. */
export async function verifySignedOutCaptcha(
  req: Request,
  userId: string | null,
  token: unknown,
  options: TurnstileOptions,
): Promise<void> {
  if (userId) return;
  await verifyTurnstile(req, token, options);
}
