// Points Stream Chat's webhook at the stream-webhook function, for reaction pushes.
//
//   SUPABASE_URL=https://<ref>.supabase.co deno run -A --env-file=supabase/functions/.env.<env> scripts/stream-webhook.ts plan
//   SUPABASE_URL=https://<ref>.supabase.co deno run -A --env-file=supabase/functions/.env.<env> scripts/stream-webhook.ts apply
//
// Needs STREAM_API_KEY, STREAM_API_SECRET and SUPABASE_URL, the project of the same environment as the
// Stream app (refs in scripts/deploy.sh). No default: a missing URL stops the script rather than point
// one environment's Stream app at another's function.
import { StreamChat } from "npm:stream-chat@9";

const EVENTS = ["reaction.new", "reaction.updated"];
const mode = Deno.args[0] ?? "plan";
const env = (name: string) =>
  Deno.env.get(name) ?? (() => {
    throw new Error(`${name} is not set`);
  })();

const client = StreamChat.getInstance(env("STREAM_API_KEY"), env("STREAM_API_SECRET"));
const base = env("SUPABASE_URL");
const url = `${base.replace(/\/$/, "")}/functions/v1/stream-webhook`;
const { app } = await client.getAppSettings();
// Stream's hook system (v2): webhooks live in `event_hooks`, one entry per destination.
const hooks = app?.event_hooks ?? [];
for (const h of hooks) console.log(`now:  ${h.hook_type} ${h.webhook_url ?? ""} [${(h.event_types ?? []).join(", ")}]`);
if (hooks.length === 0) console.log("now:  (no hooks)");
console.log(`want: webhook ${url} [${EVENTS.join(", ")}]`);

// One Stream app per environment: a stream-webhook of another Supabase project doesn't belong here.
const foreign = hooks.filter((h) => h.webhook_url?.endsWith("/functions/v1/stream-webhook") && h.webhook_url !== url);
for (const h of foreign) console.log(`drop: ${h.webhook_url}`);

if (mode === "apply") {
  const kept = hooks.filter((h) => !foreign.includes(h));
  const ours = kept.find((h) => h.webhook_url === url);
  const hook = { ...ours, hook_type: "webhook" as const, enabled: true, event_types: EVENTS, webhook_url: url };
  await client.updateAppSettings({
    event_hooks: ours ? kept.map((h) => (h === ours ? hook : h)) : [...kept, hook],
  });
  console.log("applied");
}
