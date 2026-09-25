// drafft's Stream app settings, the same in every environment. Chat channels are created by the server
// only (one per match, _shared/stream.ts), media goes through R2, and there are no guest users.
//
//   deno run -A --env-file=supabase/functions/.env.production scripts/stream-settings.ts plan
//   deno run -A --env-file=supabase/functions/.env.production scripts/stream-settings.ts apply
//
// Push providers: scripts/stream-push.ts.
import { StreamChat } from "npm:stream-chat@9";

const WANT = {
  guest_user_creation_disabled: true,
  // Stream's own uploads are unused (attachments are on R2): keep them small.
  file_upload_config: { size_limit: 1048576 },
  image_upload_config: { size_limit: 1048576 },
};
// Members may not create channels: a match creates its channel on the server.
const REVOKED_USER_GRANTS = ["create-channel"];

const mode = Deno.args[0] ?? "plan";
const env = (name: string) =>
  Deno.env.get(name) ?? (() => {
    throw new Error(`${name} is not set`);
  })();
const client = StreamChat.getInstance(env("STREAM_API_KEY"), env("STREAM_API_SECRET"));

const { app } = await client.getAppSettings();
// deno-lint-ignore no-explicit-any
const now = app as any;
console.log(`app: ${now?.name}`);
const changes: string[] = [];
if (now?.guest_user_creation_disabled !== WANT.guest_user_creation_disabled) {
  changes.push("guest_user_creation_disabled");
}
if (now?.file_upload_config?.size_limit !== WANT.file_upload_config.size_limit) {
  changes.push("file_upload_config.size_limit");
}
if (now?.image_upload_config?.size_limit !== WANT.image_upload_config.size_limit) {
  changes.push("image_upload_config.size_limit");
}

const messaging = await client.getChannelType("messaging");
const userGrants: string[] = messaging.grants?.user ?? [];
const revoke = userGrants.filter((g) => REVOKED_USER_GRANTS.includes(g));

for (const c of changes) console.log(`set:  ${c}`);
for (const g of revoke) console.log(`revoke: messaging user grant ${g}`);
if (!changes.length && !revoke.length) console.log("already as wanted");

if (mode === "apply") {
  if (changes.length) {
    // guest_user_creation_disabled is an app setting (getAppSettings returns it) missing from the SDK's
    // AppSettings type. stream-diff.ts confirms it took.
    await client.updateAppSettings(
      {
        guest_user_creation_disabled: WANT.guest_user_creation_disabled,
        file_upload_config: { ...now?.file_upload_config, ...WANT.file_upload_config },
        image_upload_config: { ...now?.image_upload_config, ...WANT.image_upload_config },
      } as Parameters<typeof client.updateAppSettings>[0],
    );
  }
  if (revoke.length) {
    await client.updateChannelType("messaging", {
      grants: { ...messaging.grants, user: userGrants.filter((g) => !REVOKED_USER_GRANTS.includes(g)) },
    });
  }
  console.log("applied");
}
