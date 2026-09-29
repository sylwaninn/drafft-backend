// Creates or updates the Stream app's two APNs push providers from the same key as the functions
// (APNS_* in the env file): `drafft-apn` for App Store / TestFlight builds, `drafft-apn-dev` (sandbox)
// for Xcode builds. Run it for each environment, and again after rotating the APNs key.
//
//   deno run -A --env-file=supabase/functions/.env.staging scripts/stream-push.ts plan
//   deno run -A --env-file=supabase/functions/.env.staging scripts/stream-push.ts apply
//
// Also sets the APNs template of message pushes (below): Stream sends them, titled with the sender's name,
// in each recipient's app language and with the text only when their message previews are on, from their
// Stream user (`drafft_push`, written by the functions from the profile: _shared/stream.ts). Preview what a
// person would get, without sending: `client.testPushSettings(<user id>, { skipDevices: true })` renders it.
//
// When the template and `drafft_push` change together: apply the template first, then deploy the functions
// and write every Stream user again. The template reads fields an older user may not have yet and falls
// back to English for them, so no push goes out broken in between.
//
// Never prints the key.
import { StreamChat } from "npm:stream-chat@9";

const mode = Deno.args[0] ?? "plan";
const env = (name: string) =>
  Deno.env.get(name) ?? (() => {
    throw new Error(`${name} is not set`);
  })();
const client = StreamChat.getInstance(
  env("STREAM_API_KEY"),
  env("STREAM_API_SECRET"),
);

const key = {
  apn_auth_type: "token" as const,
  // The functions' format (one line, \n escaped) back to a PEM.
  apn_auth_key: env("APNS_PRIVATE_KEY").replace(/\\n/g, "\n"),
  apn_key_id: env("APNS_KEY_ID"),
  apn_team_id: env("APNS_TEAM_ID"),
  apn_topic: env("APNS_BUNDLE_ID"),
};
// The title is the sender's name, or the recipient's word for "someone" when the sender has none (never an
// empty title). The body is the text with previews on, otherwise the recipient's "New message." A user not
// yet written by the functions gets English. Server messages (openers, sessions) skip Stream's push:
// db-events pushes those. `match` opens the chat, like db-events' pushes; `stream` is what Stream's own
// clients expect. Stream escapes the values for JSON.
const fallback = (field: string, english: string) =>
  `{{#if receiver.drafft_push.${field}}}{{ receiver.drafft_push.${field} }}{{else}}${english}{{/if}}`;
const title = `{{#if sender.name}}{{ sender.name }}{{else}}${fallback("someone", "Someone")}{{/if}}`;
const body = [
  "{{#if receiver.drafft_push.previews}}{{#if message.text}}{{ truncate message.text 1000 }}",
  `{{else}}${fallback("message", "New message.")}{{/if}}`,
  `{{else}}${fallback("message", "New message.")}{{/if}}`,
].join("");
const template = JSON.stringify({
  aps: {
    alert: { title, body },
    sound: "default",
    "mutable-content": 1,
    "thread-id": "{{ channel.id }}",
  },
  match: "{{ channel.id }}",
  stream: {
    sender: "stream.chat",
    type: "message.new",
    version: "v2",
    id: "{{ message.id }}",
    cid: "{{ channel.cid }}",
  },
});

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
  console.log(
    `${w.name}: now ${now}; want key ${key.apn_key_id} development ${w.apn_development}`,
  );
  console.log(
    `${w.name}: message template ${p?.apn_notification_template === template ? "as wanted" : "to set"}`,
  );
}
// Templates are read by Stream's push v2 and later.
// deno-lint-ignore no-explicit-any
const version = (app as any)?.push_notifications?.version;
console.log(
  `push version: ${version ?? "(unset)"}${version === "v1" ? " (templates need v2: set it in the dashboard)" : ""}`,
);

if (mode === "apply") {
  for (const w of WANT) {
    await client.upsertPushProvider(
      {
        ...key,
        ...w,
        type: "apn",
        description: "",
        apn_notification_template: template,
      } as Parameters<typeof client.upsertPushProvider>[0],
    );
  }
  console.log("applied");
}
