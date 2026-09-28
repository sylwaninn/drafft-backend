// POST /db-events { id, event, payload, createdAt, steps, pushUntil }, from the database outbox (pg_net),
// never from the app. The handlers and the outbox protocol are in handlers.ts.
import { env } from "../_shared/env.ts";
import { HttpError, json, readJson, safeEqual, serve } from "../_shared/http.ts";
import { type Event, runEvent } from "./handlers.ts";

serve(async (req) => {
  if (!safeEqual(req.headers.get("x-webhook-secret") ?? "", env("DB_EVENTS_SECRET"))) {
    throw new HttpError(401, "unauthorized");
  }
  await runEvent(await readJson<Event>(req));
  return json({ ok: true });
});
