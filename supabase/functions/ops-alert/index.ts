// POST /ops-alert { id, kind, incident, payload }, from the database (private.send_ops_alert, pg_net),
// never from the app. Emails one outbox alert to SUPPORT_INBOX, then acks it. Its own function, not
// db-events: it has to work when db-events doesn't.
import { env, optionalEnv } from "../_shared/env.ts";
import { HttpError, json, readJson, safeEqual, serve } from "../_shared/http.ts";
import { sendEmail } from "../_shared/mailer.ts";
import { admin, check } from "../_shared/supabase.ts";
import { type AlertKind, type OpsState, renderOpsAlert } from "./render.ts";

serve(async (req) => {
  if (!safeEqual(req.headers.get("x-webhook-secret") ?? "", env("DB_EVENTS_SECRET"))) {
    throw new HttpError(401, "unauthorized");
  }
  const { id, kind, incident, payload } = await readJson<
    { id: number; kind: AlertKind; incident: number | null; payload: OpsState }
  >(req);
  if (!["incident", "reminder", "daily"].includes(kind)) throw new HttpError(400, "invalid_kind");
  const inbox = optionalEnv("SUPPORT_INBOX");
  if (inbox) {
    await sendEmail(inbox, renderOpsAlert(kind, incident, payload ?? {}), `ops-alert-${id}`);
  } else {
    console.warn(`ops-alert: SUPPORT_INBOX not set, ${kind} alert ${id} not emailed`);
  }
  check(await admin.rpc("ack_ops_alert", { p_id: id }), "ack alert");
  return json({ ok: true });
});
