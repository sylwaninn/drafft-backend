// Sends one email. Hosted: Resend (RESEND_API_KEY). Local: MAILPIT_URL set, the email lands in the
// local Mailpit (http://127.0.0.1:55424), unless EMAIL_REAL=true sends it through Resend.
// EMAIL_FROM: `drafft <no-reply@mail.getdrafft.com>` (a Resend-verified domain; `onboarding@resend.dev` until
// then, which only delivers to the Resend account's own address).
import { env, optionalEnv } from "./env.ts";
import type { Rendered } from "./emails.ts";
import { checkResponse, viaProvider } from "./providers.ts";

/** The domain, trimmed, lowercased and without the final dot DNS allows ("a@Example.COM." is example.com). */
function domainOf(address: string): string {
  const at = address.lastIndexOf("@");
  return address.slice(at + 1).trim().toLowerCase().replace(/\.+$/, "");
}

/** Reserved names never receive mail (RFC 2606, 6761): demo and test accounts use them. The top-level
 * domains test, example, invalid and localhost (and those names on their own, `a@localhost`), and
 * example.com, .net, .org with their subdomains. */
export function isReservedAddress(address: string): boolean {
  const domain = domainOf(address);
  return /(^|\.)(test|example|invalid|localhost)$/.test(domain) || /(^|\.)example\.(com|net|org)$/.test(domain);
}

/** `idempotencyKey`: the same key within 24 h sends once (Resend), so a retried hook doesn't send twice.
 * `replyTo`: where a reply goes (the person, on the team's copy of a support request). */
export async function sendEmail(
  to: string,
  email: Rendered,
  idempotencyKey?: string,
  replyTo?: string,
): Promise<void> {
  if (isReservedAddress(to)) {
    // Never the subject or the body: an auth email's subject holds its code.
    console.log(`mailer: reserved domain ${domainOf(to)}, not sent`);
    return;
  }
  const from = env("EMAIL_FROM");
  // Locally Mailpit, unless EMAIL_REAL=true in .env.local: then Resend, as hosted.
  const mailpit = optionalEnv("EMAIL_REAL") === "true" ? undefined : optionalEnv("MAILPIT_URL");
  if (mailpit) {
    const { name, address } = parseFrom(from);
    await viaProvider("resend", async () => {
      const res = await fetch(`${mailpit}/api/v1/send`, {
        method: "POST",
        signal: AbortSignal.timeout(15_000),
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
      await checkResponse("resend", res, "mailpit");
    });
    return;
  }

  // Resend is the "resend" provider of the outbox's circuit breakers (Mailpit stands in for it locally).
  await viaProvider("resend", async () => {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      signal: AbortSignal.timeout(15_000),
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
    await checkResponse("resend", res, "resend");
  });
}

function parseFrom(from: string): { name: string; address: string } {
  const match = from.match(/^\s*(.*?)\s*<([^>]+)>\s*$/);
  return match ? { name: match[1], address: match[2] } : { name: "", address: from.trim() };
}
