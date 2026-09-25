// Points Stream Chat's webhook at the stream-webhook function, for reaction pushes.
//
//   deno run -A --env-file=supabase/functions/.env.production scripts/stream-webhook.ts plan
//   deno run -A --env-file=supabase/functions/.env.production scripts/stream-webhook.ts apply
//
// Needs STREAM_API_KEY and STREAM_API_SECRET. SUPABASE_URL defaults to the production project.
import { StreamChat } from "npm:stream-chat@9";

const EVENTS = ["reaction.new", "reaction.updated"];
const mode = Deno.args[0] ?? "plan";
const env = (name: string) =>
  Deno.env.get(name) ?? (() => {
    throw new Error(`${name} is not set`);
  })();

const client = StreamChat.getInstance(env("STREAM_API_KEY"), env("STREAM_API_SECRET"));
const base = Deno.env.get("SUPABASE_URL") ?? "https://wrcpgnqwjmnirjfxpcux.supabase.co";
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
