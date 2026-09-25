// POST /revenuecat-webhook, called by RevenueCat for every purchase event.
// Authenticated with the Authorization header value configured in RevenueCat
// (REVENUECAT_WEBHOOK_AUTH). Crediting happens in Postgres (apply_purchase_event), atomically and
// idempotently, so RevenueCat's retries are harmless.
import { env } from "../_shared/env.ts";
import { HttpError, json, readJson, safeEqual, serve } from "../_shared/http.ts";
import { admin } from "../_shared/supabase.ts";

serve(async (req) => {
  if (!safeEqual(req.headers.get("authorization") ?? "", env("REVENUECAT_WEBHOOK_AUTH"))) {
    throw new HttpError(401, "unauthorized");
  }
  const { event } = await readJson<{ event?: Record<string, unknown> }>(req);
  if (!event) throw new HttpError(400, "missing_event");

  const { data, error } = await admin.rpc("apply_purchase_event", { p_event: event });
  // A failure answers 500: RevenueCat retries with backoff.
  if (error) throw new Error(`apply_purchase_event ${event.id}: ${error.message}`);
  console.log(`revenuecat ${event.type} ${event.product_id ?? ""}: ${data}`);
  return json({ ok: true, effect: data });
});
