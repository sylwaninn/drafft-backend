// The contract between the support mail Worker (cloudflare/support-mail-worker) and the support-inbound function:
// one payload, one result, parsed the same way on both sides. The Worker imports this file (its bundle takes it
// in), so it uses nothing but the language: no Deno, no npm.

/** The most text the Worker posts. The function keeps 8000 characters in a thread, 4000 in a new request, and
 * says when it cut (`truncated`). */
export const MAX_TEXT = 20_000;

/** What the Worker posts to support-inbound. */
export interface Inbound {
  /** The envelope sender (SMTP MAIL FROM), never the From header. */
  from: string;
  subject: string;
  /** What the person wrote this time, cut to MAX_TEXT. */
  text: string;
  reference: string | null;
  messageId: string | null;
  /** The attachments' names only. */
  attachments: string[];
  /** Cloudflare's own Authentication-Results (authserv-id mx.cloudflare.net), or null. */
  authentication: string | null;
  /** SPF passed for the envelope's domain, or DKIM passed aligned with it (Cloudflare's results). */
  verified: boolean;
}

export type InboundOutcome = "appended" | "created" | "duplicate";

/** What support-inbound answers. */
export interface InboundResult {
  outcome: InboundOutcome;
  reference: string | null;
  truncated: boolean;
}

/** A payload that isn't one: the function answers 400. */
export class InboundError extends Error {}

const string = (value: unknown, name: string, max: number): string => {
  if (typeof value !== "string") throw new InboundError(`${name} must be text`);
  return value.trim().slice(0, max);
};
const nullable = (value: unknown, name: string, max: number): string | null =>
  value === null || value === undefined ? null : string(value, name, max) || null;

/** The payload, checked field by field; anything of the wrong type is refused, never coerced. */
export function parseInbound(json: unknown): Inbound {
  if (typeof json !== "object" || json === null || Array.isArray(json)) throw new InboundError("not an object");
  const body = json as Record<string, unknown>;
  const attachments = body.attachments ?? [];
  if (!Array.isArray(attachments) || !attachments.every((a) => typeof a === "string")) {
    throw new InboundError("attachments must be a list of names");
  }
  if (typeof body.verified !== "boolean") throw new InboundError("verified must be true or false");
  return {
    from: string(body.from, "from", 320),
    subject: string(body.subject ?? "", "subject", 998),
    text: string(body.text ?? "", "text", MAX_TEXT),
    reference: nullable(body.reference, "reference", 20),
    messageId: nullable(body.messageId, "messageId", 998),
    attachments: (attachments as string[]).map((a) => a.slice(0, 100)).slice(0, 20),
    authentication: nullable(body.authentication, "authentication", 1000),
    verified: body.verified,
  };
}

/** The function's answer, or null when it isn't one (the Worker then keeps the whole email another way). */
export function parseInboundResult(json: unknown): InboundResult | null {
  if (typeof json !== "object" || json === null) return null;
  const r = json as Record<string, unknown>;
  if (!["appended", "created", "duplicate"].includes(r.outcome as string)) return null;
  if (!(r.reference === null || typeof r.reference === "string") || typeof r.truncated !== "boolean") return null;
  return { outcome: r.outcome as InboundOutcome, reference: r.reference as string | null, truncated: r.truncated };
}

const bytes = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).length;

/**
 * What the team sees next to a new request: whether the sender was verified, the attachments' names (never their
 * content) and Cloudflare's authentication results, within `budget` bytes of JSON (a request's context holds 2000,
 * and the database adds a few fields): the authentication goes first, then names from the end.
 */
export function inboundContext(inbound: Inbound, budget = 1500): Record<string, unknown> {
  const context: Record<string, unknown> = { verified: inbound.verified };
  if (inbound.authentication) context.authentication = inbound.authentication;
  if (inbound.attachments.length > 0) context.attachments = [...inbound.attachments];
  if (bytes(context) > budget) delete context.authentication;
  const names = context.attachments as string[] | undefined;
  let left = 0;
  while (names && names.length > 0 && bytes({ ...context, moreAttachments: left + 1 }) > budget) {
    names.pop();
    left++;
  }
  if (left > 0) context.moreAttachments = left;
  if (names && names.length === 0) delete context.attachments;
  return context;
}
