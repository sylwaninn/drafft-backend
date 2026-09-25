// Creates or updates the Stream app's two APNs push providers from the same key as the functions
// (APNS_* in the env file): `drafft-apn` for App Store / TestFlight builds, `drafft-apn-dev` (sandbox)
// for Xcode builds. Run it for each environment, and again after rotating the APNs key.
//
//   deno run -A --env-file=supabase/functions/.env.staging scripts/stream-push.ts plan
//   deno run -A --env-file=supabase/functions/.env.staging scripts/stream-push.ts apply
//
// Never prints the key.
import { StreamChat } from "npm:stream-chat@9";

const mode = Deno.args[0] ?? "plan";
const env = (name: string) =>
  Deno.env.get(name) ?? (() => {
    throw new Error(`${name} is not set`);
  })();
const client = StreamChat.getInstance(env("STREAM_API_KEY"), env("STREAM_API_SECRET"));

const key = {
  apn_auth_type: "token" as const,
  // The functions' format (one line, \n escaped) back to a PEM.
  apn_auth_key: env("APNS_PRIVATE_KEY").replace(/\\n/g, "\n"),
  apn_key_id: env("APNS_KEY_ID"),
  apn_team_id: env("APNS_TEAM_ID"),
  apn_topic: env("APNS_BUNDLE_ID"),
};
const WANT = [
  { name: "drafft-apn", apn_development: false },
  { name: "drafft-apn-dev", apn_development: true },
];

const { app } = await client.getAppSettings();
// deno-lint-ignore no-explicit-any
const providers: any[] = (app as any)?.push_notifications?.providers ?? [];
console.log(`app: ${app?.name}`);
for (const w of WANT) {
  const p = providers.find((x) => x.name === w.name);
  const now = p
    ? `key ${p.apn_key_id} team ${p.apn_team_id} topic ${p.apn_topic} development ${p.apn_development ?? false}`
    : "(missing)";
  console.log(`${w.name}: now ${now}; want key ${key.apn_key_id} development ${w.apn_development}`);
}

if (mode === "apply") {
  for (const w of WANT) {
    await client.upsertPushProvider(
      { ...key, ...w, type: "apn", description: "" } as Parameters<typeof client.upsertPushProvider>[0],
    );
  }
  console.log("applied");
}
