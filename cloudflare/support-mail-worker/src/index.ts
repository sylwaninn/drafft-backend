// drafft support mail: what people write to the support address (support@getdrafft.com) goes back into the
// request it answers, in sophros.
//
// Cloudflare Email Routing hands each email sent to that address to this Worker (an Email Worker: `email()`,
// no HTTP route). It reads the email (postal-mime), keeps what the person wrote this time (message.ts: quoted
// history and signature cut off, attachments by name only) and the [DR-XXXXXX] reference of its request, and
// posts that to the `support-inbound` Edge Function with the shared secret. The function files it in its
// request and reopens it, or opens a new request (docs/support.md, "Support by email").
//
// Never lose a message: the whole email is forwarded to FALLBACK_ADDRESS (the team's mailbox, a verified
// destination of Email Routing) whenever the function didn't take it (unreachable, an error, over the limits),
// when it isn't a person writing (an auto-reply, a bounce, a mailing list), and as a copy when part of it
// couldn't be filed (attachments, a text cut to size, their own lines cut with the quoted history). When even
// that forward fails, the Worker throws: Email Routing then refuses the email, and the sender's server reports or
// retries it.
import PostalMime from "postal-mime";
import { type Inbound, MAX_TEXT, parseInboundResult } from "../../../supabase/functions/_shared/support_inbound.ts";
import { automatic, cloudflareResults, findReference, htmlToText, stripQuoted, verifiedSender } from "./message.ts";

export type { Inbound };

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

type Parsed = Awaited<ReturnType<typeof PostalMime.parse>>;

/**
 * The email as support-inbound takes it (_shared/support_inbound.ts). The sender is the envelope's (SMTP MAIL FROM),
 * not the From header's, which anyone can write, and it counts as verified only when Cloudflare's own results
 * vouch for it: only a verified address may add to its requests or be linked to an account. `cut`: the text was
 * longer than MAX_TEXT; `dropped`: some of what they wrote was cut with the quoted history.
 */
export function toInbound(email: IncomingEmail, parsed: Parsed): { inbound: Inbound; cut: boolean; dropped: boolean } {
  const subject = (parsed.subject ?? "").trim();
  // An empty text part next to an HTML one: the HTML says what they wrote.
  const plain = parsed.text?.trim() ? parsed.text : "";
  const full = plain || (parsed.html ? htmlToText(parsed.html) : "");
  const { text, dropped } = stripQuoted(full);
  const attachments = parsed.attachments.map((a) => a.filename || a.mimeType || "attachment");
  // The first Authentication-Results in the message (Cloudflare's own, on top), else the runtime's view of it.
  const first = parsed.headers.find((h) => h.key.toLowerCase() === "authentication-results")?.value ??
    email.headers.get("authentication-results")?.split(/,\s*(?=[\w.-]+\s*;)/)[0] ?? null;
  const authentication = cloudflareResults(first);
  return {
    inbound: {
      from: email.from.trim(),
      subject,
      text: text.slice(0, MAX_TEXT),
      // In the quoted history too, <blockquote>s included: that is where a reply carries it.
      reference: findReference(subject, plain || (parsed.html ? htmlToText(parsed.html, { quotes: true }) : "")),
      messageId: parsed.messageId?.trim() || null,
      attachments,
      authentication: authentication?.slice(0, 1000) ?? null,
      verified: verifiedSender(email.from, authentication),
    },
    cut: text.length > MAX_TEXT,
    dropped,
  };
}

/** What happened to one email, for the logs and the tests. */
export type Outcome = "filed" | "filed, copy kept" | "kept";

/** A header value Email Routing accepts: printable ASCII on one line. */
const headerValue = (text: string) => text.replace(/[^\x20-\x7e]/g, "?").slice(0, 200);

/** Why the whole email must also go to the fallback address, and whether support-inbound filed it anyway. */
type Fallback = { filed: boolean; reason: string };

/** Files the email with support-inbound: null when all of it was filed, else why (part of) it wasn't. */
async function file(email: IncomingEmail, env: Env, post: typeof fetch): Promise<Fallback | null> {
  const parsed = await PostalMime.parse(await new Response(email.raw).arrayBuffer());
  const why = automatic(email.from, email.headers);
  if (why) return { filed: false, reason: `not filed: ${why}` };
  const { inbound, cut, dropped } = toInbound(email, parsed);
  const res = await post(env.SUPPORT_INBOUND_URL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-support-inbound-secret": env.SUPPORT_INBOUND_SECRET },
    body: JSON.stringify(inbound),
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) {
    return {
      filed: false,
      reason: `not filed: support-inbound answered ${res.status} ${headerValue(await res.text())}`,
    };
  }
  const result = parseInboundResult(await res.json().catch(() => null));
  if (!result) return { filed: false, reason: "not filed: support-inbound answered something else than a result" };
  console.log(`support mail: ${result.outcome} ${result.reference ?? ""}`);
  const missing: string[] = [];
  if (inbound.attachments.length > 0) missing.push(`${inbound.attachments.length} attachment(s)`);
  if (cut || result.truncated) missing.push("text cut to size");
  if (dropped) missing.push("text left out with the quoted history");
  if (missing.length === 0) return null;
  return { filed: true, reason: `filed as ${result.reference ?? "?"}, not all of it: ${missing.join(", ")}` };
}

export async function receive(email: IncomingEmail, env: Env, post: typeof fetch = fetch): Promise<Outcome> {
  let fallback: Fallback | null;
  try {
    fallback = await file(email, env, post);
  } catch (error) {
    fallback = { filed: false, reason: `not filed: ${String(error)}` };
  }
  if (fallback === null) return "filed";
  console.warn(`support mail: ${fallback.reason}, forwarded to the fallback address`);
  await email.forward(env.FALLBACK_ADDRESS, new Headers({ "X-Drafft-Support": headerValue(fallback.reason) }));
  return fallback.filed ? "filed, copy kept" : "kept";
}

export default {
  async email(email: IncomingEmail, env: Env): Promise<void> {
    await receive(email, env);
  },
};
