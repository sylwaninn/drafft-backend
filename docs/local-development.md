# Local development

## Setup

The commands are in the README ([Getting started](../README.md#getting-started)). Beyond them:

- **Apple and Google sign-in values** for `config.toml`, optional: `cp supabase/.env.example supabase/.env`.
- **Ports** 55420-55429, so the stack runs next to other Supabase projects. Load the areas again
  (`deno run -A scripts/load-areas.ts local`) after each `supabase db reset`.
- **`scripts/local-env.sh`** writes `supabase/functions/.env.local` once, from `.env.staging` with local
  values; the file is yours to edit after, and the script never rewrites it.
- **`scripts/sync-vault.sh local`** puts the media signing secrets in the local Vault, so cards get photo
  links (served by staging's media Worker). `supabase/seed.sql` already holds the local Vault secrets the
  outbox needs (`edge_functions_url`, `db_events_secret`) and `dev@drafft.local`, the staff admin sophros
  uses in dev mode.
- **The apps:** `scripts/local-backend.sh` in drafft-ios or drafft-android (`--device` for a phone on the same
  Wi-Fi) points the iOS **Drafft Local** scheme or the Android `local` build variant at this stack.

### Fully offline

Without `functions/.env.staging`: copy `supabase/functions/.env.example` to `supabase/functions/.env.local`
instead, point `R2_ENDPOINT` at the local Storage S3 API (`http://host.docker.internal:55421/storage/v1/s3`,
`R2_REGION=local`, keys from `supabase status`) and create a public `drafft-media` bucket.

### Supabase CLI version

CI pins the CLI (`SUPABASE_CLI` in `.github/workflows/backend.yml`, 2.90 today). The Postgres image bundled
with CLI 2.90 (17.6.1.106) crashes when a role calls a function it has no EXECUTE on from psql, so tests check
privileges with `has_function_privilege`; through the API the same call correctly returns 42501. Keep this
note in step with the pin.

## Local database, staging services

The local apps (iOS scheme **Drafft Local**, Android build variant `local`, both named "drafft local" on the
phone) run on this local Supabase, while chat, media, pushes, moderation and purchases go through the staging
services.

In `.env.local`, `EMAIL_REAL=true` / `SMS_REAL=true` send auth emails (Resend, your own key if you set one)
and SMS (Twilio) for real instead of to Mailpit (http://127.0.0.1:55424). `scripts/local-env.sh` never
rewrites the file once it exists.

Outgoing calls just work. Incoming webhooks still go to staging, which ignores users it doesn't know
(`ignored: unknown app_user_id`). To credit local purchases, expose the functions with a tunnel
(`cloudflared tunnel --url http://localhost:55421`) and add a **second** webhook in RevenueCat `drafft staging`
to `https://<tunnel>/functions/v1/revenuecat-webhook`, Authorization from
`scripts/local-env.sh --webhook-auth | pbcopy`. Never repoint staging's own webhooks (RevenueCat, Stream).
Local users and media land in Stream staging and `drafft-media-staging`; a `supabase db reset` leaves them
orphaned there.
