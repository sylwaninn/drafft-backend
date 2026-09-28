// POST /purchase-sync → the caller's wallet (super_likes, boosts, boost_ends_at, premium_until, weekly_boost_at)
// Called by the app right after a purchase or a restore: reads the caller's purchases from RevenueCat
// (REST API v2, REVENUECAT_SECRET_KEY and REVENUECAT_PROJECT_ID) and applies them in Postgres
// (apply_purchase_sync), so the credit doesn't wait for the webhook. Each consumable is credited once per
// store transaction, shared with revenuecat-webhook; premium_until is copied from drafft_tempo.
// Limits: 1 call per 5 seconds and 30 per hour and account (429 too_many_requests).
import { optionalEnv } from "../_shared/env.ts";
import { HttpError, json, serve } from "../_shared/http.ts";
import { admin, requireUser } from "../_shared/supabase.ts";
import { readState, RevenueCatError } from "./revenuecat.ts";

serve(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
  const user = await requireUser(req);

  const secretKey = optionalEnv("REVENUECAT_SECRET_KEY");
  const projectId = optionalEnv("REVENUECAT_PROJECT_ID");
  if (!secretKey || !projectId) {
    console.error("purchase-sync: REVENUECAT_SECRET_KEY or REVENUECAT_PROJECT_ID is not set");
    throw new HttpError(503, "sync_not_configured");
  }

  const begin = await admin.rpc("purchase_sync_begin", { p_user: user.id });
  if (begin.error) {
    if (begin.error.hint === "too_many_requests") throw new HttpError(429, "too_many_requests");
    throw new Error(`purchase_sync_begin: ${begin.error.message}`);
  }

  let state;
  try {
    state = await readState(fetch, secretKey, projectId, user.id, begin.data as string);
  } catch (error) {
    console.error(`purchase-sync ${user.id}: ${error instanceof RevenueCatError ? error.message : error}`);
    throw new HttpError(503, "sync_unavailable");
  }

  const { data, error } = await admin.rpc("apply_purchase_sync", { p_user: user.id, p_state: state });
  if (error) throw new Error(`apply_purchase_sync ${user.id}: ${error.message}`);
  return json(data);
});
