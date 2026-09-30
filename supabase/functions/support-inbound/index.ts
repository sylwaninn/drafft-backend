// POST /support-inbound { from, subject, text, reference?, messageId?, attachments?, authentication? }
//   → { outcome: "appended" | "created" | "duplicate", reference, truncated }
//
// An email written to the support address (support@getdrafft.com), posted by the support mail Worker
// (cloudflare/support-mail-worker) after Cloudflare Email Routing handed it over, never by the app. The header
// `x-support-inbound-secret` must equal SUPPORT_INBOUND_SECRET (the Worker's secret of the same name).
//
// receive_support_email (migration 20260930000501) does the rest: with the reference of a request written from
// its address, the message joins that request as the member's and reopens it; otherwise a new request from the
// sender (topic "email", linked to the account with that email if any, the form's limits and acknowledgement).
// Answers 429 past the limits and 400 on what can't be a message: the Worker then keeps the email another way
// (its fallback address), so nothing is lost.
import { env } from "../_shared/env.ts";
import { HttpError, json, safeEqual, serve } from "../_shared/http.ts";
import { admin } from "../_shared/supabase.ts";

interface Body {
  from?: unknown;
  subject?: unknown;
  text?: unknown;
  reference?: unknown;
  messageId?: unknown;
  attachments?: unknown;
  authentication?: unknown;
}

/** The Worker sends the text already cut to a message's size: anything much bigger isn't from it. */
const MAX_BODY_BYTES = 256 * 1024;
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const text = (value: unknown, max: number) => typeof value === "string" ? value.trim().slice(0, max) : "";

/** What the team sees next to a new request: the attachments' names (never their content) and how the
 * sender's server authenticated (SPF, DKIM, DMARC), within the 2000 bytes a request's context holds. */
export function inboundContext(body: Body): Record<string, unknown> {
  const context: Record<string, unknown> = {};
  const names = Array.isArray(body.attachments)
    ? body.attachments.filter((n): n is string => typeof n === "string").map((n) => n.slice(0, 100)).slice(0, 10)
    : [];
  if (names.length > 0) context.attachments = names;
  const authentication = text(body.authentication, 600);
  if (authentication) context.authentication = authentication;
  return context;
}

serve(async (req) => {
  if (!safeEqual(req.headers.get("x-support-inbound-secret") ?? "", env("SUPPORT_INBOUND_SECRET"))) {
    throw new HttpError(401, "unauthorized");
  }
  if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) throw new HttpError(413, "too_large");
  let body: Body;
  try {
    body = JSON.parse(raw) as Body;
  } catch {
    throw new HttpError(400, "invalid_json");
  }

  const from = text(body.from, 320);
  if (!emailPattern.test(from)) throw new HttpError(400, "invalid_email");
  const { data, error } = await admin.rpc("receive_support_email", {
    p_from: from,
    p_subject: text(body.subject, 998),
    p_body: text(body.text, 20_000),
    p_reference: text(body.reference, 20) || null,
    p_message_id: text(body.messageId, 998) || null,
    p_context: inboundContext(body),
  });
  if (error) {
    if (error.hint === "too_many_requests") throw new HttpError(429, "too_many_requests");
    if (error.hint === "invalid_email" || error.hint === "empty_message") throw new HttpError(400, error.hint);
    throw new Error(`support inbound: ${error.message}`);
  }
  return json(data);
});
