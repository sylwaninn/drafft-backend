// The team's outbox alerts (private.ops_check and ops_daily, migrations 20260928000121 and 20260930000101),
// as emails to SUPPORT_INBOX. Only what the database sends is shown, and it sends counts, event names,
// providers and job names: no payload, no address, no error text. The failed events themselves are in
// sophros, Failed events.
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
  // Daily jobs (privacy-purge, outbox-cleanup) with no completed run in 26 hours, or a failed one since.
  jobsBehind?: { job: string; lastRunAt: string | null }[];
  // Daily summary: what each job's last run deleted, by step.
  jobs?: Record<string, Record<string, unknown>>;
}

export type AlertKind = "incident" | "reminder" | "daily";

const n = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : 0);

function byEvent(counts: Record<string, number> | undefined): string {
  const entries = Object.entries(counts ?? {}).filter(([event]) => /^[a-z_.]{1,60}$/.test(event));
  return entries.length === 0 ? "none" : entries.sort().map(([event, count]) => `${event}: ${n(count)}`).join("\n");
}

function providers(list: string[] | undefined): string {
  const known = (list ?? []).filter((p) => ["stream", "apns", "fcm", "resend", "twilio", "r2"].includes(p));
  return known.length === 0 ? "none" : known.join(", ");
}

const isName = (value: unknown) => typeof value === "string" && /^[A-Za-z_.-]{1,60}$/.test(value);

function jobsBehind(list: OpsState["jobsBehind"]): string {
  const known = (list ?? []).filter((j) => isName(j?.job));
  return known.length === 0 ? "none" : known.map((j) => `${j.job}: last completed ${time(j.lastRunAt)}`).join("\n");
}

// A nested count (outbox-cleanup's dead letters by event) is summed.
function stepTotal(value: unknown): number {
  if (typeof value === "object" && value !== null) {
    return Object.values(value).reduce((sum: number, v) => sum + n(v), 0);
  }
  return n(value);
}

// One line per job, its steps and their counts: only names and numbers get through.
function jobCounts(jobs: OpsState["jobs"]): string {
  const lines = Object.entries(jobs ?? {}).filter(([job]) => isName(job)).sort().map(([job, counts]) => {
    const steps = Object.entries(counts ?? {})
      .filter(([step]) => isName(step))
      .map(([step, value]) => `${step} ${stepTotal(value)}`);
    return `${job}: ${steps.length === 0 ? "nothing" : steps.join(", ")}`;
  });
  return lines.length === 0 ? "no run in the last 24 hours" : lines.join("\n");
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
    ["Daily jobs behind", jobsBehind(state.jobsBehind)],
  ];
  const next: [string, string] = [
    "What to do",
    "sophros, Failed events: replay or discard each one. A job behind: its runs in cron.job_run_details.",
  ];
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
      ["Deleted by the daily jobs", jobCounts(state.jobs)],
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
