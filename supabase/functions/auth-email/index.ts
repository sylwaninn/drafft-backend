// POST /auth-email: Supabase Auth's Send Email hook. Auth sends no email itself: it calls this for each one
// and we send it, in the person's language (profiles.language, which the sign-up sets from the app).
// Signed with the hook's secret (Standard Webhooks, SEND_EMAIL_HOOK_SECRET: `v1,whsec_…` from Auth > Hooks).
// The reset link goes through Auth's /verify, then back to the app (drafft://auth-callback/reset). The
// other emails carry a 6-digit code the app types in (verifyOTP).
import { type AuthEmail, renderAuthEmail } from "../_shared/emails.ts";
import { env, optionalEnv } from "../_shared/env.ts";
import { hookError, hookOk, verifyHook } from "../_shared/hook.ts";
import { sendEmail } from "../_shared/mailer.ts";
import { admin } from "../_shared/supabase.ts";
import { language } from "../_shared/texts.ts";

type Payload = {
  user: { id: string; email: string; new_email?: string; user_metadata?: Record<string, unknown> };
  email_data: {
    token: string;
    token_hash: string;
    token_new: string;
    token_hash_new: string;
    redirect_to: string;
    email_action_type: string;
  };
};

// The emails the app triggers; Auth's others (magic link, invite) aren't used.
const kinds: Record<string, AuthEmail> = {
  signup: "confirm",
  recovery: "reset",
  email_change: "newEmail",
  reauthentication: "reauth",
};

Deno.serve(async (req) => {
  const payload = await verifyHook<Payload>(req, "SEND_EMAIL_HOOK_SECRET", "auth-email");
  if (!payload) return hookError(401, "invalid signature");

  const { user, email_data: data } = payload;
  const type = data.email_action_type;
  try {
    const kind = kinds[type];
    if (!kind) {
      // Security notifications (password changed…) are off in Auth; if one is turned on, it needs a template.
      if (type.endsWith("_notification")) {
        console.warn(`auth-email: no template for ${type}, not sent`);
        return hookOk();
      }
      throw new Error(`no template for ${type}`);
    }

    const { data: profile } = await admin.from("profiles").select("language").eq("id", user.id).maybeSingle();
    const lang = language(profile?.language ?? user.user_metadata?.language);

    let to = user.email;
    let vars: { link?: string; code?: string; email?: string };
    if (kind === "reset") {
      vars = { link: verifyLink(data.token_hash, type, data.redirect_to) };
    } else if (kind === "newEmail") {
      // One code, to the new address (double_confirm_changes is off): whichever token Auth filled in.
      if (!user.new_email) throw new Error("email_change without new_email");
      to = user.new_email;
      vars = { code: data.token || data.token_new, email: user.new_email };
    } else {
      // Sign-up and reauthentication: a code the app types in.
      vars = { code: data.token };
    }

    await sendEmail(to, renderAuthEmail(kind, lang, vars), req.headers.get("webhook-id") ?? undefined);
    console.log(`auth-email: ${type} ${lang}`);
    return hookOk();
  } catch (error) {
    console.error(`auth-email: ${type}`, error);
    return hookError(500, "email not sent");
  }
});

/** Auth's own verify endpoint: it checks the token, then redirects to the app with the session. */
function verifyLink(tokenHash: string, type: string, redirectTo: string): string {
  // Locally SUPABASE_URL is the Docker-internal address: AUTH_PUBLIC_URL is the one a phone can open.
  const base = optionalEnv("AUTH_PUBLIC_URL") ?? env("SUPABASE_URL");
  const params = new URLSearchParams({ token: tokenHash, type, redirect_to: redirectTo });
  return `${base}/auth/v1/verify?${params}`;
}
