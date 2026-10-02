# Environments and deploys

Two hosted environments: production (Supabase project `wrcpgnqwjmnirjfxpcux`) and staging, a persistent
Supabase branch named `staging` of `drafft-backend` (its own database, Auth, Storage, Edge Functions, keys and
URL), fed with the same migrations. The apps' staging builds point at staging (iOS scheme **Drafft Staging**,
Android build variant `staging`, both "drafft β" on the phone, same app id as production). Everything goes to
staging first: a merge into `staging` (the default branch) deploys it, then a release deploys to production.
Development runs against staging only: there is no local stack, the local database exists only inside CI.

| | Production | Staging |
|---|---|---|
| Supabase | `wrcpgnqwjmnirjfxpcux` | branch `staging`, ref `rjlghcuspdtrmbimyioe` |
| Edge Functions secrets | `functions/.env.production` | `functions/.env.staging` |
| R2 bucket (EU jurisdiction) | `drafft-media` | `drafft-media-staging` |
| Media Worker (signed links, `MEDIA_PUBLIC_URL`) | `drafft-media`, `media.getdrafft.com` | `drafft-media-staging`, `media-staging.getdrafft.com` |
| Support mail Worker | `drafft-support-mail`, `support@` | `drafft-support-mail-staging`, `support-staging@` |
| Stream | app `drafft` (EU) | app `drafft-staging` (EU) |
| RevenueCat | project `drafft` (`proj3dc1aebd`) | project `drafft staging` (`proje5eb803d`), same catalog |
| APNs, Rekognition | shared (same bundle id, same key) | shared |
| Play Integrity | shared (same service account, same project number, one Play app); Device recall's bits are shared too, so a test hold on staging marks a real device for production | shared |
| DeviceCheck key | shared, `DEVICECHECK_ENVIRONMENT=production` | shared, `development` for Xcode installs, `production` for TestFlight |

## Deploys and releases

GitHub Actions (`.github/workflows/backend.yml`) deploys without anyone stepping in:

- **Every pull request** is checked: Deno format, lint, type checks and unit tests (including the copy against
  [WORDING.md](../WORDING.md)), the Workers' tests, database tests, advisors and the migration guard.
- **A push to `staging`** deploys staging: `scripts/deploy.sh staging` (migrations, Edge Functions, areas),
  then the media Worker, then the drift check.
- **A `v*` tag** deploys production the same way (the `production` environment only accepts `v*` tags and
  `main`). Tags come from Actions > release > Run workflow (`.github/workflows/release.yml`,
  `scripts/ci/release.sh`): with staging's head green, it fast-forwards `main` to `staging`, tags the next
  version (from the released pull request titles: `type!:` major, `feat` minor, else patch; or the one asked
  for), publishes a GitHub release and starts the production deploy on that tag.

CI ships code only: migrations, Edge Functions, areas and the media Worker. Secrets are set by hand, always
naming the project: `deploy.sh staging --secrets` or
`supabase secrets set --project-ref <ref> --env-file supabase/functions/.env.<env>`. Auth settings live in the
dashboard, and the support mail Worker is deployed by hand ([support.md](support.md#support-by-email)).

### Supabase CLI version

CI pins the CLI (`SUPABASE_CLI` in `.github/workflows/backend.yml`, 2.90 today). The Postgres image bundled
with CLI 2.90 (17.6.1.106) crashes when a role calls a function it has no EXECUTE on from psql, so tests check
privileges with `has_function_privilege`; through the API the same call correctly returns 42501. Keep this
note in step with the pin.

### Roll back

Actions > backend > Run workflow on an older tag redeploys that tag. `deploy.sh` runs `supabase db push`
first, which refuses when the database holds migrations the tag doesn't have: after a release that added
migrations, roll forward instead (a new migration that undoes the change, released as usual). Migrations are
never rolled back.

## Staging setup

Done once; kept to rebuild it.

1. `supabase branches create staging --persistent --region eu-west-1`. Its ref goes in six files here:
   `scripts/deploy.sh`, `scripts/sync-vault.sh`, `scripts/load-areas.ts`, `scripts/demo/guard.ts`,
   `scripts/ci/env-parity.sh` and `cloudflare/support-mail-worker/wrangler.jsonc` (`SUPPORT_INBOUND_URL`);
   its URL and publishable key in drafft-ios `Config/Staging.xcconfig` and drafft-android
   `config/staging.properties`, its URL in drafft-sophros `wrangler.jsonc`.
2. `scripts/deploy.sh staging`.
3. `functions/.env.staging` from `.env.example`: same APNs and Rekognition values as production; its own
   `FCM_SERVICE_ACCOUNT` (the staging Firebase project's service account),
   R2 token (bucket `drafft-media-staging`, EU), `R2_BUCKET=drafft-media-staging`,
   `R2_ENDPOINT=https://<account>.eu.r2.cloudflarestorage.com` (EU jurisdiction buckets only answer there),
   `MEDIA_PUBLIC_URL=https://media-staging.getdrafft.com` (the media Worker) and its own `MEDIA_SIGNING_KEY`
   (`openssl rand -hex 32`, the same in the Worker and sophros: [media.md](media.md)), the Stream staging
   app's keys,
   and fresh random `DB_EVENTS_SECRET` and `REVENUECAT_WEBHOOK_AUTH` (`openssl rand -hex 32`), and
   `REVENUECAT_SECRET_KEY` (a v2 secret key of `drafft staging`, read-only on customer information and
   project configuration) with `REVENUECAT_PROJECT_ID=proje5eb803d` for `purchase-sync`. Then
   `scripts/deploy.sh staging --secrets`. Wrangler needs `--jurisdiction eu` to see either bucket.
4. `scripts/sync-vault.sh staging`: the database's Vault secrets (`edge_functions_url`, `db_events_secret`
   from `DB_EVENTS_SECRET`, `purchase_environment`, `media_base_url` and `media_signing_key` from
   `MEDIA_PUBLIC_URL` and `MEDIA_SIGNING_KEY`), so database events reach the functions. Run it again whenever
   `DB_EVENTS_SECRET` changes. Production's Vault is never written by a script (see Production setup).
5. Auth on the branch: Apple and Google (same client ids as production), Send Email hook to its `auth-email`
   (its own secret and Resend key).
6. Stream staging app (EU), configured by script like production, `--env-file=supabase/functions/.env.<env>`:
   `stream-settings.ts` (app settings, grants), `stream-push.ts` (APNs providers `drafft-apn` and
   `drafft-apn-dev` from `APNS_*`, and the message push template), `stream-webhook.ts` (`SUPABASE_URL` of the
   same environment, required). `stream-diff.ts` compares the two apps. The Firebase push provider
   `drafft-fcm` (the staging Firebase project's service account) is added by hand in Stream's dashboard.
7. RevenueCat project `drafft staging`: same apps, products, entitlement and offerings as `drafft`
   (identifiers included), App Store Connect API key and In-App Purchase key uploaded, webhook →
   staging `revenuecat-webhook` with `REVENUECAT_WEBHOOK_AUTH` as its Authorization header. Any catalog
   change goes to both projects. Its public SDK keys are in drafft-ios `Config/Staging.xcconfig` (`appl_`) and
   drafft-android `config/staging.properties` (`goog_`).
8. App Store Server Notifications (V2): production URL → RevenueCat `drafft`, sandbox URL → RevenueCat
   `drafft staging` (`scripts/app-store-notifications.ts`). Production TestFlight builds buy in the
   sandbox, so their server notifications go to staging; their SDK still syncs on launch.
   Each database only credits purchases from its own store environment, the Vault secret
   `purchase_environment` read by `apply_purchase_event`: `PRODUCTION` when unset (production), `SANDBOX`
   on staging (`sync-vault.sh`) and in CI's database (`seed.sql`). Other events are recorded, not credited
   (`ignored: sandbox event`, `ignored: production event`).

## Production setup

Done once already; kept for the record, not to replay. Production changes only through CI: a `v*` tag (made by
Actions > release) runs `scripts/deploy.sh production` in `.github/workflows/backend.yml` (migrations,
functions and areas, after the checks), which links the CLI back to staging afterwards. Never `supabase link`
the production project and `db push` or `functions deploy` by hand. No script writes to production from a
laptop (`deploy.sh` and `sync-vault.sh` refuse it): the only manual writes are the secrets and the Vault below.

1. Supabase project `wrcpgnqwjmnirjfxpcux`, **West EU (Ireland)**. Before the public launch: compute Small or
   larger, and point-in-time recovery (PITR).
2. Migrations and Edge Functions: a release (see [Deploys and releases](#deploys-and-releases)).
   `scripts/deploy.sh production` refuses to run outside GitHub Actions on a `v*` tag: no production deploy
   from a laptop. To redeploy, Actions > backend > Run workflow on the tag.
3. Vault secrets, from the dashboard's SQL editor (`vault.create_secret`, or `vault.update_secret` to change
   one): `edge_functions_url` (`https://wrcpgnqwjmnirjfxpcux.supabase.co/functions/v1`), `db_events_secret`
   (the same value as `DB_EVENTS_SECRET` in step 4), `media_base_url` and `media_signing_key` (the same
   values as `MEDIA_PUBLIC_URL` and `MEDIA_SIGNING_KEY`). `purchase_environment` stays unset: `PRODUCTION`
   is the default. Change `DB_EVENTS_SECRET` and the Vault together, or database events stop reaching the
   functions.
4. Function secrets:
   `supabase secrets set --project-ref wrcpgnqwjmnirjfxpcux --env-file supabase/functions/.env.production`
   (see `functions/.env.example`), **without** `MODERATION_MODE`. Always with `--project-ref`: the CLI stays
   linked to staging, so without it the production secrets would land in staging.
5. Auth: Apple (bundle id `so.drafft.app`) and Google (iOS + web client ids) in the dashboard. Send Email hook
   (HTTPS) to `auth-email`: its secret into `SEND_EMAIL_HOOK_SECRET`, with `RESEND_API_KEY` and `EMAIL_FROM`,
   then the secrets as in step 4 before enabling it.
6. R2 bucket `drafft-media`, private, served only by the media Worker (`cloudflare/media-worker`) on
   `media.getdrafft.com`, with `MEDIA_SIGNING_KEY` and `MEDIA_PUBLIC_URL`: see [media.md](media.md).
7. Stream app in the EU region: the APNs providers by `scripts/stream-push.ts`, and the Firebase push provider
   `drafft-fcm` (the production Firebase project's service account) added by hand in its push settings (chat
   pushes come from Stream). `FCM_SERVICE_ACCOUNT` in the function secrets: a service account key of the
   production Firebase project (the one of the Android app's production `google-services.json`), the JSON on one
   line; db-events sends Android's pushes with it (`_shared/fcm.ts`), by each token's `platform`.
8. Moderation and support secrets: `DEVICECHECK_KEY_ID` and `DEVICECHECK_PRIVATE_KEY` (an Apple key with
   DeviceCheck; the team comes from `APNS_TEAM_ID`), `DEVICECHECK_ENVIRONMENT=production` (Apple's environment
   is chosen by the project, never by the app), `PLAY_INTEGRITY_SERVICE_ACCOUNT` (the JSON key of a service
   account of the Google Cloud project linked in Play Console's App integrity page, with the Play Integrity
   API enabled and Device recall on) and `PLAY_CLOUD_PROJECT_NUMBER` (that project's number, which the app
   uses: the server only checks that it is set; both are needed, and with either one unset Android device
   checks are skipped and logged; `PLAY_PACKAGE_NAME` only if the app id isn't `so.drafft.app`; Google's
   default quota is 10,000 decodes a day for the whole project, shared by both projects: ask for more in
   Play Console before Android has thousands of daily users, and alert on the quota in Google Cloud),
   `TWILIO_LOOKUP_API_KEY_SID` and `_SECRET` (a US1 API key,
   required: every verification SMS goes to a mobile line Lookup accepted, and none goes out without it),
   `SUPPORT_INBOX` (the team's copy of support requests, reports and exports it must finish by hand),
   optionally `EXPORT_MAX_BYTES` (the most one export part weighs, in bytes:
   47185920, 45 MiB, when unset; keep it under the Storage upload limit; anything but a positive whole number
   fails the export), `SUPPORT_INBOUND_SECRET` and `SUPPORT_ADDRESS` ([support.md](support.md#support-by-email)),
   `TURNSTILE_SECRET_KEY` (the Turnstile widget's secret key: required in both projects, the
   signed-out support form is refused without it and `scripts/ci/env-parity.sh` flags a project missing it).
   Otherwise unset, each feature is skipped and logged. The Vault secret `identity_hash_key` is
   created by migration `20260927000004`: never delete or rotate it, every ban and hold mark would be lost.
   The team acts through sophros (`admin_*` functions, audited in `private.admin_audit`).
