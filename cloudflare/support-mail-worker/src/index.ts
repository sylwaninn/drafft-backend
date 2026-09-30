// drafft support mail: what people write to the support address (support@getdrafft.com) goes back into the
// request it answers, in sophros.
//
// Cloudflare Email Routing hands each email sent to that address to this Worker (an Email Worker: `email()`,
// no HTTP route). It reads the email (postal-mime), keeps what the person wrote this time (message.ts: quoted
// history and signature cut off, attachments by name only) and the [DR-XXXXXX] reference of its request, and
// posts that to the `support-inbound` Edge Function with the shared secret. The function files it in its
// request and reopens it, or opens a new request (README, "Support by email").
//
// Never lose a message: the whole email is forwarded to FALLBACK_ADDRESS (the team's mailbox, a verified
// destination of Email Routing) whenever the function didn't take it (unreachable, an error, over the limits),
// when it isn't a person writing (an auto-reply, a bounce, a mailing list), and as a copy when part of it
// couldn't be filed (attachments, a text cut to size). When even that forward fails, the Worker throws: Email
// Routing then refuses the email, and the sender's server reports or retries it.
import PostalMime from "postal-mime";
import { automatic, findReference, htmlToText, stripQuoted } from "./message.ts";

// Minimal shapes of the Workers runtime APIs used here (no @cloudflare/workers-types dependency, so Deno
// checks and tests this Worker like the rest of the repository).
export interface IncomingEmail {
  /** The envelope sender (SMTP MAIL FROM), which SPF vouches for. */
  readonly from: string;
  readonly to: string;
  readonly headers: Headers;
  readonly raw: ReadableStream<Uint8Array>;
  readonly rawSize: number;
  forward(rcptTo: string, headers?: Headers): Promise<unknown>;
}
export interface Env {
  /** https://<project>.supabase.co/functions/v1/support-inbound */
  SUPPORT_INBOUND_URL: string;
  /** Equal to the function's SUPPORT_INBOUND_SECRET. */
  SUPPORT_INBOUND_SECRET: string;
  /** Where the whole email goes when it can't be filed, or not all of it. */
  FALLBACK_ADDRESS: string;
}

/** The most text posted: the function keeps 8000 characters in a thread, 4000 in a new request, and says so. */
const MAX_TEXT = 20_000;

/** What support-inbound receives. */
export interface Inbound {
  from: string;
  subject: string;
  text: string;
  reference: string | null;
  messageId: string | null;
  attachments: string[];
  authentication: string | null;
}

type Parsed = Awaited<ReturnType<typeof PostalMime.parse>>;

/**
 * The email as support-inbound takes it. The sender is the envelope's (SMTP MAIL FROM, which SPF vouches for),
 * not the From header's, which anyone can write: only the address a request was written from may add to it.
 */
export function toInbound(email: IncomingEmail, parsed: Parsed): { inbound: Inbound; cut: boolean } {
  const subject = (parsed.subject ?? "").trim();
  const full = parsed.text ?? (parsed.html ? htmlToText(parsed.html) : "");
  const text = stripQuoted(full);
  const attachments = parsed.attachments.map((a) => a.filename || a.mimeType || "attachment");
  return {
    inbound: {
      from: email.from.trim(),
      subject,
      text: text.slice(0, MAX_TEXT),
      reference: findReference(subject, full),
      messageId: parsed.messageId?.trim() || null,
      attachments,
      authentication: email.headers.get("authentication-results")?.slice(0, 600) ?? null,
    },
    cut: text.length > MAX_TEXT,
  };
}

/** What happened to one email, for the logs and the tests. */
export type Outcome = "filed" | "filed, copy kept" | "kept";

/** A header value Email Routing accepts: printable ASCII on one line. */
const headerValue = (text: string) => text.replace(/[^\x20-\x7e]/g, "?").slice(0, 200);

export async function receive(email: IncomingEmail, env: Env, post: typeof fetch = fetch): Promise<Outcome> {
  let reason: string;
  let filed = false;
  try {
    const parsed = await PostalMime.parse(await new Response(email.raw).arrayBuffer());
    const why = automatic(email.from, email.headers);
    if (why) {
      reason = `not filed: ${why}`;
    } else {
      const { inbound, cut } = toInbound(email, parsed);
      const res = await post(env.SUPPORT_INBOUND_URL, {
        method: "POST",
        headers: { "content-type": "application/json", "x-support-inbound-secret": env.SUPPORT_INBOUND_SECRET },
        body: JSON.stringify(inbound),
        signal: AbortSignal.timeout(15_000),
      });
      if (!res.ok) {
        reason = `not filed: support-inbound answered ${res.status} ${headerValue(await res.text())}`;
      } else {
        const result = await res.json() as { outcome?: string; reference?: string; truncated?: boolean };
        filed = true;
        console.log(`support mail: ${result.outcome} ${result.reference ?? ""}`);
        const missing = [
          ...(inbound.attachments.length > 0 ? [`${inbound.attachments.length} attachment(s)`] : []),
          ...(cut || result.truncated ? ["text cut to size"] : []),
        ];
        if (missing.length === 0) return "filed";
        reason = `filed as ${result.reference ?? "?"}, not all of it: ${missing.join(", ")}`;
      }
    }
  } catch (error) {
    reason = `not filed: ${String(error)}`;
  }
  console.warn(`support mail: ${reason}, forwarded to the fallback address`);
  await email.forward(env.FALLBACK_ADDRESS, new Headers({ "X-Drafft-Support": headerValue(reason) }));
  return filed ? "filed, copy kept" : "kept";
}

export default {
  async email(email: IncomingEmail, env: Env): Promise<void> {
    await receive(email, env);
  },
};
