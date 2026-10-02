# Local development

## Setup

```sh
cp supabase/.env.example supabase/.env   # Apple and Google values for config.toml, optional
supabase start            # ports 55420-55429, so it runs next to other Supabase projects
supabase test db          # pgTAP tests (supabase/tests/database)
deno run -A scripts/load-areas.ts local   # the areas for area_at; again after a db reset
scripts/local-env.sh      # once: functions/.env.local from .env.staging with local values; yours to edit after
scripts/sync-vault.sh local   # the media signing secrets in the local Vault: cards get photo links (staging's Worker)
supabase functions serve --env-file supabase/functions/.env.local
# in drafft-ios or drafft-android: scripts/local-backend.sh (--device for a phone on the same Wi-Fi)
```

Without `functions/.env.staging` (fully offline): copy `supabase/functions/.env.example` to
`supabase/functions/.env.local` instead, point `R2_ENDPOINT` at the local Storage S3 API
(`http://host.docker.internal:55421/storage/v1/s3`, `R2_REGION=local`, keys from `supabase status`) and create
a public `drafft-media` bucket.

Update the CLI (`brew upgrade supabase`): the Postgres image bundled with CLI 2.90 (17.6.1.106) crashes when
a role calls a function it has no EXECUTE on from psql. Tests check privileges with `has_function_privilege`
for that reason. Through the API the same call correctly returns 42501.

## Local database, staging services

The app's **Drafft Local** scheme ("drafft local") runs on this local Supabase, started as above, while
chat, media, pushes, moderation and purchases go through the staging services.

In `.env.local`, `EMAIL_REAL=true` / `SMS_REAL=true` send auth emails (Resend, your own key if you set one)
and SMS (Twilio) for real instead of to Mailpit. The script never rewrites the file once it exists.

Outgoing calls just work. Incoming webhooks still go to staging, which ignores users it doesn't know
(`ignored: unknown app_user_id`). To credit local purchases, expose the functions with a tunnel
(`cloudflared tunnel --url http://localhost:55421`) and add a **second** webhook in RevenueCat `drafft staging`
to `https://<tunnel>/functions/v1/revenuecat-webhook`, Authorization from
`scripts/local-env.sh --webhook-auth | pbcopy`. Never repoint staging's own webhooks (RevenueCat, Stream).
Local users and media land in Stream staging and `drafft-media-staging`; a `supabase db reset` leaves them
orphaned there.
