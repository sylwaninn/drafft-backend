// Sends one email. Hosted: Resend (RESEND_API_KEY). Local: MAILPIT_URL set, the email lands in the
// local Mailpit (http://127.0.0.1:55424) and never leaves the machine.
// EMAIL_FROM: `drafft <no-reply@mail.getdrafft.com>` (a Resend-verified domain; `onboarding@resend.dev` until
// then, which only delivers to the Resend account's own address).
import { env, optionalEnv } from "./env.ts";
import type { Rendered } from "./emails.ts";

/** `idempotencyKey`: the same key within 24 h sends once (Resend), so a retried hook doesn't send twice.
 * `replyTo`: where a reply goes (the person, on the team's copy of a support request). */
export async function sendEmail(
  to: string,
  email: Rendered,
  idempotencyKey?: string,
  replyTo?: string,
): Promise<void> {
  const from = env("EMAIL_FROM");
  // Locally Mailpit, unless EMAIL_REAL=true in .env.local: then Resend, as hosted.
  const mailpit = optionalEnv("EMAIL_REAL") === "true" ? undefined : optionalEnv("MAILPIT_URL");
  if (mailpit) {
    const { name, address } = parseFrom(from);
    const res = await fetch(`${mailpit}/api/v1/send`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        From: { Email: address, Name: name },
        To: [{ Email: to }],
        ...(replyTo ? { ReplyTo: [{ Email: replyTo }] } : {}),
        Subject: email.subject,
        HTML: email.html,
        Text: email.text,
      }),
    });
    if (!res.ok) throw new Error(`mailpit ${res.status}: ${await res.text()}`);
    return;
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env("RESEND_API_KEY")}`,
      "content-type": "application/json",
      ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}),
    },
    body: JSON.stringify({
      from,
      to: [to],
      ...(replyTo ? { reply_to: replyTo } : {}),
      subject: email.subject,
      html: email.html,
      text: email.text,
    }),
  });
  if (!res.ok) throw new Error(`resend ${res.status}: ${await res.text()}`);
}

function parseFrom(from: string): { name: string; address: string } {
  const match = from.match(/^\s*(.*?)\s*<([^>]+)>\s*$/);
  return match ? { name: match[1], address: match[2] } : { name: "", address: from.trim() };
}
