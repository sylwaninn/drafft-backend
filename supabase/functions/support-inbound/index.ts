// POST /support-inbound { from, subject, text, reference, messageId, attachments, authentication, verified }
//   → { outcome: "appended" | "created" | "duplicate", reference, truncated }
//
// An email written to the support address (support@getdrafft.com), posted by the support mail Worker
// (cloudflare/support-mail-worker) after Cloudflare Email Routing handed it over, never by the app. The header
// `x-support-inbound-secret` must equal SUPPORT_INBOUND_SECRET (the Worker's secret of the same name). The
// payload and the answer are those of _shared/support_inbound.ts, which the Worker parses the same way.
//
// receive_support_email (migration 20260930000501) does the rest. A sender Cloudflare verified (`verified`: SPF
// for the envelope's domain, or aligned DKIM): with the reference of a request written from its address, the
// message joins that request as the member's and reopens it; otherwise a new request, linked to the account with
// that email if any, acknowledged. An unverified sender: always a new request, linked to no account, never
// acknowledged. Answers 429 past the limits and 400 on what can't be a message: the Worker then keeps the email
// another way (its fallback address), so nothing is lost.
import { env } from "../_shared/env.ts";
import { HttpError, json, safeEqual, serve } from "../_shared/http.ts";
import { admin } from "../_shared/supabase.ts";
import { inboundContext, InboundError, parseInbound } from "../_shared/support_inbound.ts";

/** The Worker posts the text cut to 20 000 characters: anything much bigger isn't from it. */
const MAX_BODY_BYTES = 256 * 1024;
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

serve(async (req) => {
  if (!safeEqual(req.headers.get("x-support-inbound-secret") ?? "", env("SUPPORT_INBOUND_SECRET"))) {
    throw new HttpError(401, "unauthorized");
  }
  if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) throw new HttpError(413, "too_large");
  let inbound;
  try {
    inbound = parseInbound(JSON.parse(raw));
  } catch (error) {
    if (error instanceof SyntaxError) throw new HttpError(400, "invalid_json");
    if (error instanceof InboundError) throw new HttpError(400, "invalid_payload");
    throw error;
  }
  if (!emailPattern.test(inbound.from)) throw new HttpError(400, "invalid_email");
  const { data, error } = await admin.rpc("receive_support_email", {
    p_from: inbound.from,
    p_subject: inbound.subject,
    p_body: inbound.text,
    p_reference: inbound.reference,
    p_message_id: inbound.messageId,
    p_context: inboundContext(inbound),
    p_verified: inbound.verified,
  });
  if (error) {
    if (error.hint === "too_many_requests") throw new HttpError(429, "too_many_requests");
    if (error.hint === "invalid_email" || error.hint === "empty_message") throw new HttpError(400, error.hint);
    throw new Error(`support inbound: ${error.message}`);
  }
  return json(data);
});
