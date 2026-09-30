// What the support mail Worker keeps of an email: who sent it, the reference of its request, what they wrote
// this time (quoted history and signature cut off), the names of its attachments. Pure functions, tested on
// their own (message_test.ts).

/** A support reference as create_support_request makes them: DR- and 6 of A–Z (no I, no O) and 2–9. */
const REFERENCE = /\bDR-([A-HJ-NP-Z2-9]{6})\b/i;

/** The reference in the subject ("Re: Help [DR-ABC234]"), else anywhere in the text (a client that rewrote the
 * subject still quotes the email it answers). Uppercase, or null. */
export function findReference(subject: string, text: string): string | null {
  const match = subject.match(REFERENCE) ?? text.match(REFERENCE);
  return match ? `DR-${match[1].toUpperCase()}` : null;
}

// The line a mail client writes above the message it quotes, in the app's 7 languages, and the separators some
// clients use instead (Outlook's underscores, "Original Message" banners).
const ATTRIBUTION = [
  /^On\b.*\bwrote\s?:?$/i,
  /^Le\b.*\ba écrit\s?:?$/i,
  /^El\b.*\bescribió\s?:?$/i,
  /^Am\b.*\bschrieb\b.*:$/i,
  /^Il\b.*\bha scritto\s?:?$/i,
  /^(Em|No dia)\b.*\bescreveu\s?:?$/i,
  /^Op\b.*\bschreef\b.*:$/i,
];
const SEPARATOR = [
  /^-{2,}\s*(Original Message|Message d'origine|Mensaje original|Ursprüngliche Nachricht|Messaggio originale|Mensagem original|Oorspronkelijk bericht)\s*-{2,}$/i,
  /^_{10,}$/,
];
// Outlook's header block: "From: …" then, within 3 lines, "Sent: …" (or its translation).
const HEADER_FROM = /^(From|De|Von|Da|Van)\s?:\s?\S/i;
const HEADER_SENT = /^(Sent|Date|Envoyé|Enviado|Gesendet|Datum|Inviato|Verzonden)\s?:\s?\S/i;
// The rest of a quoted header block: never someone's own words.
const HEADER_OTHER = /^(To|Cc|Subject|À|Objet|Para|Asunto|An|Betreff|A|Oggetto|Assunto|Aan|Onderwerp)\s?:/i;

/** Where the quoted history starts (a line index), or the text's length when nothing is quoted. */
function historyStart(lines: string[]): number {
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    // A long attribution wraps: "On Mon, 30 Sep 2026 at 10:00, drafft <" / "no-reply@…> wrote:".
    const next = (lines[i + 1] ?? "").trim();
    if (ATTRIBUTION.some((r) => r.test(line))) return i;
    if (line && next && !ATTRIBUTION.some((r) => r.test(next)) && ATTRIBUTION.some((r) => r.test(`${line} ${next}`))) {
      return i;
    }
    if (SEPARATOR.some((r) => r.test(line))) return i;
    if (HEADER_FROM.test(line) && lines.slice(i + 1, i + 4).some((l) => HEADER_SENT.test(l.trim()))) return i;
    // The signature delimiter ("-- "): what follows is the signature.
    if (lines[i] === "-- " || lines[i] === "--") return i;
  }
  return lines.length;
}

/** The support address or a reference: the quoted block is our own email coming back. */
const OURS = /\bDR-[A-HJ-NP-Z2-9]{6}\b|getdrafft\.com/i;

/**
 * What they wrote this time: the quoted history, quoted lines ("> …") and the signature cut off. When that
 * leaves nothing (a reply written inside the quote), the whole text: never lose what someone wrote.
 * `dropped`: lines of their own that were cut (not quoted with ">", not our own email quoted back, not a short
 * signature). The attribution patterns also match ordinary sentences ("he wrote:"), so the Worker then keeps a
 * copy of the whole email for the team.
 */
export function stripQuoted(text: string): { text: string; dropped: boolean } {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const start = historyStart(lines);
  const kept = lines.slice(0, start).filter((l) => !/^\s*>/.test(l));
  const result = kept.join("\n").replace(/\n{3,}/g, "\n\n").trim();
  if (!result) return { text: text.trim(), dropped: false };
  // The attribution itself, on one line or wrapped over two.
  const first = (lines[start] ?? "").trim();
  const wrapped = !ATTRIBUTION.some((r) => r.test(first)) &&
    ATTRIBUTION.some((r) => r.test(`${first} ${(lines[start + 1] ?? "").trim()}`));
  const rest = lines.slice(start + (wrapped ? 2 : 1)).map((l) => l.trim())
    .filter((l) => l !== "" && !/^>/.test(l) && ![HEADER_FROM, HEADER_SENT, HEADER_OTHER].some((r) => r.test(l)));
  const signature = (lines[start] === "-- " || lines[start] === "--") && rest.length <= 4;
  // Our own email quoted back without ">" (Outlook's style): its lines aren't theirs. With ">" quoting, a line
  // without it is an answer written between the quotes.
  const ours = !lines.slice(start + 1).some((l) => /^\s*>/.test(l)) && OURS.test(lines.slice(start).join("\n"));
  return { text: result, dropped: rest.length > 0 && !signature && !ours };
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

/** An HTML-only email as plain text: paragraphs and line breaks kept, quoted blocks (<blockquote>, nested ones
 * too) and styles dropped unless `quotes` keeps them, entities decoded. Good enough for a support message; the
 * team gets the whole email when unsure. */
export function htmlToText(html: string, options: { quotes?: boolean } = {}): string {
  let text = html.replace(/<(style|script|head)\b[\s\S]*?<\/\1>/gi, "");
  if (!options.quotes) {
    // Innermost first, until none is left: a nested quote never leaves its outer one's tail behind.
    const innermost = /<blockquote\b[^>]*>(?:(?!<blockquote\b)[\s\S])*?<\/blockquote>/gi;
    while (innermost.test(text)) text = text.replace(innermost, "");
  }
  return text
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|tr|h[1-6]|blockquote)>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&(#\d+|#x[0-9a-f]+|[a-z]+);/gi, (entity, name: string) => {
      if (name[0] === "#") {
        const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : Number(name.slice(1));
        return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
      }
      return ENTITIES[name.toLowerCase()] ?? entity;
    })
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Cloudflare's own Authentication-Results: the first such header, and only when Cloudflare wrote it (authserv-id
 * mx.cloudflare.net). A copy further down, or one naming another server, is anyone's to write. */
export function cloudflareResults(first: string | null): string | null {
  if (!first) return null;
  return /^\s*mx\.cloudflare\.net\s*;/i.test(first) ? first.trim() : null;
}

const domainOf = (address: string) => address.trim().replace(/^<|>$/g, "").split("@").pop()!.toLowerCase();
const aligned = (a: string, b: string) => a === b || a.endsWith(`.${b}`) || b.endsWith(`.${a}`);

/**
 * Whether the envelope sender is vouched for by Cloudflare's results: SPF passed for the envelope's own domain,
 * or a DKIM signature passed for a domain aligned with it (the same, or one a subdomain of the other).
 */
export function verifiedSender(envelopeFrom: string, results: string | null): boolean {
  if (!results || !envelopeFrom.includes("@")) return false;
  const domain = domainOf(envelopeFrom);
  // Comments ("(mx.cloudflare.net: domain of … designates …)") say nothing to rely on.
  const clauses = results.replace(/\([^)]*\)/g, " ").split(";").slice(1).map((c) => c.trim().toLowerCase());
  return clauses.some((clause) => {
    const method = clause.match(/^(spf|dkim)\s*=\s*(\w+)/);
    if (!method || method[2] !== "pass") return false;
    if (method[1] === "spf") {
      const from = clause.match(/smtp\.mailfrom\s*=\s*"?([^\s";]+)/)?.[1];
      return !!from && domainOf(from) === domain;
    }
    const d = clause.match(/header\.d\s*=\s*"?([^\s";]+)/)?.[1] ?? clause.match(/header\.i\s*=\s*"?@?([^\s";]+)/)?.[1];
    return !!d && aligned(domainOf(d), domain);
  });
}

/**
 * Why an email isn't a person writing (null when it is): an auto-reply, a bounce, a mailing list. Those are
 * kept for the team (the fallback address), never filed: an out-of-office answering the acknowledgement
 * would otherwise open request after request.
 */
export function automatic(envelopeFrom: string, headers: Headers): string | null {
  const auto = headers.get("auto-submitted")?.trim().toLowerCase();
  if (auto && auto !== "no") return `auto-submitted: ${auto}`;
  if (headers.has("x-autoreply") || headers.has("x-autorespond")) return "auto-reply";
  const precedence = headers.get("precedence")?.trim().toLowerCase();
  if (precedence && ["bulk", "junk", "list", "auto_reply"].includes(precedence)) return `precedence: ${precedence}`;
  if (headers.has("list-id") || headers.has("list-unsubscribe")) return "mailing list";
  const sender = envelopeFrom.trim().toLowerCase();
  if (!sender || sender === "<>" || /^(mailer-daemon|postmaster)@/.test(sender)) return "bounce";
  if (/multipart\/report/i.test(headers.get("content-type") ?? "")) return "delivery report";
  return null;
}
