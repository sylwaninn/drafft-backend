// Compares the production and staging Stream apps: app settings, push providers and channel types.
// Prints only what differs, never keys or secrets. Expected differences: the webhook URL.
//
//   deno run -A scripts/stream-diff.ts
//
// Reads STREAM_API_KEY / STREAM_API_SECRET from supabase/functions/.env.production and .env.staging.
import { StreamChat } from "npm:stream-chat@9";

function streamKeys(file: string): [string, string] {
  const vars: Record<string, string> = {};
  for (const line of Deno.readTextFileSync(file).split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?(STREAM_API_KEY|STREAM_API_SECRET)\s*=\s*(.*?)\s*$/);
    if (m) vars[m[1]] = m[2].replace(/^(["'])(.*)\1$/, "$2");
  }
  if (!vars.STREAM_API_KEY || !vars.STREAM_API_SECRET) throw new Error(`Stream keys missing in ${file}`);
  return [vars.STREAM_API_KEY, vars.STREAM_API_SECRET];
}

// Values that identify the app or change on their own, not configuration.
const IGNORED = /(^|\.)(id|name|organization|created_at|updated_at|cdn_expiration_seconds|suspended|suspended_explanation|webhook_url|before_message_send_hook_url|event_hooks\.\d+\.(id|webhook_url|created_at|updated_at))$|secret|private_key|p12|credentials|api_key/i;

// Lists compare by content, not position: primitives sorted, objects keyed by their name.
function label(item: unknown, i: number): string {
  const o = item as Record<string, unknown>;
  return String(o?.name ?? o?.description ?? o?.type ?? i).trim() || String(i);
}

function flatten(value: unknown, path = "", out: Record<string, string> = {}): Record<string, string> {
  if (Array.isArray(value)) {
    if (value.every((v) => v === null || typeof v !== "object")) {
      if (!IGNORED.test(path)) out[path] = JSON.stringify([...value].sort());
    } else {
      value.forEach((v, i) => flatten(v, `${path}[${label(v, i)}]`, out));
    }
  } else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) flatten(v, path ? `${path}.${k}` : k, out);
  } else if (!IGNORED.test(path)) {
    out[path] = JSON.stringify(value);
  }
  return out;
}

async function snapshot(file: string) {
  const [key, secret] = streamKeys(file);
  const client = new StreamChat(key, secret);
  const { app } = await client.getAppSettings();
  const { channel_types } = await client.listChannelTypes();
  return { name: app?.name ?? "?", key, flat: flatten({ app, channel_types }) };
}

const prod = await snapshot("supabase/functions/.env.production");
const staging = await snapshot("supabase/functions/.env.staging");
console.log(`production: ${prod.name}   staging: ${staging.name}   same app: ${prod.key === staging.key ? "YES (wrong)" : "no"}`);

const paths = [...new Set([...Object.keys(prod.flat), ...Object.keys(staging.flat)])].sort();
const diffs = paths.filter((p) => prod.flat[p] !== staging.flat[p]);
for (const p of diffs) console.log(`${p}\n  production: ${prod.flat[p] ?? "(absent)"}\n  staging:    ${staging.flat[p] ?? "(absent)"}`);
console.log(diffs.length ? `${diffs.length} difference(s).` : "Identical configuration.");
