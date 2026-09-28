// The team's outbox alerts (private.ops_check and ops_daily, migration 20260928000121), as emails to
// SUPPORT_INBOX. Only what the database sends is shown, and it sends counts, event names and providers:
// no payload, no address, no error text. The failed events themselves are in sophros, Failed events.
import type { Rendered } from "../_shared/emails.ts";
import { renderTeamEmail } from "../_shared/notices.ts";

export interface OpsState {
  failed?: number;
  failedByEvent?: Record<string, number>;
  oldestFailedAt?: string | null;
  waiting?: number;
  late?: number;
  oldestLateAt?: string | null;
  openCircuits?: string[];
  openedAt?: string | null;
  delivered?: number;
  expired?: number;
  discarded?: number;
  newlyFailed?: number;
  incidents?: number;
}

export type AlertKind = "incident" | "reminder" | "daily";

const n = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : 0);

function byEvent(counts: Record<string, number> | undefined): string {
  const entries = Object.entries(counts ?? {}).filter(([event]) => /^[a-z_.]{1,60}$/.test(event));
  return entries.length === 0 ? "none" : entries.sort().map(([event, count]) => `${event}: ${n(count)}`).join("\n");
}

function providers(list: string[] | undefined): string {
  const known = (list ?? []).filter((p) => ["stream", "apns", "resend", "twilio", "r2"].includes(p));
  return known.length === 0 ? "none" : known.join(", ");
}

function time(value: string | null | undefined): string {
  const at = value ? new Date(value) : null;
  return at && !Number.isNaN(at.getTime()) ? `${at.toISOString().slice(0, 16).replace("T", " ")} UTC` : "none";
}

export function renderOpsAlert(kind: AlertKind, incident: number | null, state: OpsState): Rendered {
  const now: [string, string][] = [
    ["Failed events", `${n(state.failed)}\n${byEvent(state.failedByEvent)}`],
    ["Oldest failure", time(state.oldestFailedAt)],
    ["Providers down", providers(state.openCircuits)],
    ["Waiting for a provider", String(n(state.waiting))],
    ["Undelivered for over 30 minutes", `${n(state.late)} (oldest ${time(state.oldestLateAt)})`],
  ];
  const next: [string, string] = ["What to do", "sophros, Failed events: replay or discard each one."];
  if (kind === "daily") {
    return renderTeamEmail("[outbox] daily summary", [
      [
        "Last 24 hours",
        [
          `Delivered: ${n(state.delivered)}`,
          `Failed: ${n(state.newlyFailed)}`,
          `Dropped as stale: ${n(state.expired)}`,
          `Discarded by the team: ${n(state.discarded)}`,
          `Incidents: ${n(state.incidents)}`,
        ].join("\n"),
      ],
      ...now,
      next,
    ]);
  }
  const ref = incident ? ` #${incident}` : "";
  if (kind === "reminder") {
    return renderTeamEmail(`[outbox] incident${ref} still open`, [
      ["Open since", time(state.openedAt)],
      ...now,
      next,
    ]);
  }
  return renderTeamEmail(`[outbox] incident${ref}`, [...now, next]);
}
