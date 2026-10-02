# Environments and deploys

A persistent Supabase branch named `staging` of `drafft-backend` (its own database, Auth, Storage, Edge
Functions, keys and URL), fed with the same migrations. The app's **Drafft Staging** scheme points at it
(`drafft β` on the home screen, same bundle id as production). Everything goes to staging first: a merge
into `staging` (the default branch) deploys it, then a release deploys to production.

| | Production | Staging |
|---|---|---|
| Supabase | `wrcpgnqwjmnirjfxpcux` | branch `staging` (ref in `scripts/deploy.sh`) |
| Edge Functions secrets | `functions/.env.production` | `functions/.env.staging` |
| R2 bucket (EU jurisdiction) | `drafft-media` | `drafft-media-staging` |
| Public media URL (until the domain) | `pub-f4b77604ea6f42188c3ba8da914a6a16.r2.dev` | `pub-2877e6f189f0420785f5cd685f44f789.r2.dev` |
| Media Worker (signed links) | `drafft-media`, `media.getdrafft.com` | `drafft-media-staging`, `media-staging.getdrafft.com` |
| Support mail Worker | `drafft-support-mail`, `support@getdrafft.com` | `drafft-support-mail-staging`, `support-staging@getdrafft.com` |
| Stream | app `drafft` (EU) | app `drafft-staging` (EU) |
| RevenueCat | project `drafft` (`proj3dc1aebd`) | project `drafft staging` (`proje5eb803d`), same catalog |
| APNs, Rekognition | shared (same bundle id, same key) | shared |
| DeviceCheck key | shared, `DEVICECHECK_ENVIRONMENT=production` | shared, `DEVICECHECK_ENVIRONMENT` matching how staging builds are installed (`development` from Xcode, `production` from TestFlight) |

## Deploys and releases

GitHub Actions (`.github/workflows/backend.yml`) does it on its own: every pull request is checked
(Deno type checks, unit tests including the copy against [WORDING.md](../WORDING.md), database tests), a push to `staging` deploys to staging, and a `v*` tag deploys to
production (the `production` environment only accepts `v*` tags and `main`). Tags come from Actions > release >
Run workflow (`.github/workflows/release.yml`, `scripts/ci/release.sh`): with staging's head green, it
fast-forwards `main` to `staging`, tags the next version (from the released pull request titles: `type!:`
major, `feat` minor, else patch; or the one asked for), publishes a GitHub release and starts the production
deploy on that tag. To roll back, Actions > backend > Run workflow on an older tag. Migrations and functions only:
secrets are still set by hand, always naming the project: `deploy.sh <env> --secrets` or
`supabase secrets set --project-ref <ref> --env-file supabase/functions/.env.<env>`.

## Staging setup

Done once; kept to rebuild it.

1. `supabase branches create staging --persistent --region eu-west-1`, then its ref and publishable key into
   `scripts/deploy.sh` and the app's `Config/Staging.xcconfig`.
2. `scripts/deploy.sh staging`.
3. `functions/.env.staging` from `.env.example`: same APNs and Rekognition values as production; its own
   `FCM_SERVICE_ACCOUNT` (the staging Firebase project's service account),
   R2 token (bucket `drafft-media-staging`, EU), `R2_BUCKET=drafft-media-staging`,
   `R2_ENDPOINT=https://<account>.eu.r2.cloudflarestorage.com` (EU jurisdiction buckets only answer there),
   `MEDIA_PUBLIC_URL=https://pub-2877e6f189f0420785f5cd685f44f789.r2.dev`, the Stream staging app's keys,
   and fresh random `DB_EVENTS_SECRET` and `REVENUECAT_WEBHOOK_AUTH` (`openssl rand -hex 32`), and
   `REVENUECAT_SECRET_KEY` (a v2 secret key of `drafft staging`, read-only on customer information and
   project configuration) with `REVENUECAT_PROJECT_ID=proje5eb803d` for `purchase-sync`. Then
   `scripts/deploy.sh staging --secrets`. Wrangler needs `--jurisdiction eu` to see either bucket.
4. `scripts/sync-vault.sh staging`: the database's Vault secrets (`edge_functions_url`, `db_events_secret`
   from `DB_EVENTS_SECRET`, `purchase_environment`, `media_base_url` and `media_signing_key` from
   `MEDIA_PUBLIC_URL` and `MEDIA_SIGNING_KEY`), so database events reach the functions. Run it again whenever `DB_EVENTS_SECRET`
   changes, in either environment.
5. Auth on the branch: Apple and Google (same client ids as production), Send Email hook to its `auth-email`
   (its own secret and Resend key).
6. Stream staging app (EU), configured by script like production, `--env-file=supabase/functions/.env.<env>`:
   `stream-settings.ts` (app settings, grants), `stream-push.ts` (APNs providers from `APNS_*`),
   `stream-webhook.ts` (`SUPABASE_URL` of the same environment, required). `stream-diff.ts` compares the two apps.
7. RevenueCat project `drafft staging`: same apps, products, entitlement and offerings as `drafft`
   (identifiers included), App Store Connect API key and In-App Purchase key uploaded, webhook →
   staging `revenuecat-webhook` with `REVENUECAT_WEBHOOK_AUTH` as its Authorization header. Any catalog
   change goes to both projects. Its public SDK key is in the app's `Config/Staging.xcconfig`.
8. App Store Server Notifications (V2): production URL → RevenueCat `drafft`, sandbox URL → RevenueCat
   `drafft staging` (`scripts/app-store-notifications.ts`). Production TestFlight builds buy in the
   sandbox, so their server notifications go to staging; their SDK still syncs on launch.
   Each database only credits purchases from its own store environment, the Vault secret
   `purchase_environment` read by `apply_purchase_event`: `PRODUCTION` when unset (production), `SANDBOX`
   on staging (`sync-vault.sh`) and locally (`seed.sql`). Other events are recorded, not credited
   (`ignored: sandbox event`, `ignored: production event`).

## Production setup

Done once already; kept for the record, not to replay. Production changes only through CI: a `v*` tag (made by
Actions > release) runs
`scripts/deploy.sh production` in `.github/workflows/backend.yml` (migrations and functions, after the checks),
which links the CLI back to staging afterwards. Never `supabase link` the production project and `db push`
or `functions deploy` by hand.

1. Supabase project `wrcpgnqwjmnirjfxpcux`, **West EU (Ireland)**; compute Small or larger and PITR before the public launch.
2. Migrations and Edge Functions: a release (see [Deploys and releases](#deploys-and-releases)). `scripts/deploy.sh production` by hand is a
   fallback only, from that tag's checkout: it asks to type `production`.
3. `scripts/sync-vault.sh production` (Vault secrets, from `functions/.env.production`; it asks to type
   `production`).
4. Function secrets: `supabase secrets set --project-ref wrcpgnqwjmnirjfxpcux --env-file supabase/functions/.env.production`
   (see `functions/.env.example`), **without** `MODERATION_MODE`. Always with `--project-ref`: the CLI stays
   linked to staging, so without it the production secrets would land in staging.
5. Auth: Apple (bundle id `so.drafft.app`) and Google (iOS + web client ids) in the dashboard. Send Email hook
   (HTTPS) to `auth-email`: its secret into `SEND_EMAIL_HOOK_SECRET`, with `RESEND_API_KEY` and `EMAIL_FROM`,
   then the secrets as in step 4 before enabling it.
6. R2 bucket `drafft-media`, private, served only by the media Worker (`cloudflare/media-worker`) on
   `media.getdrafft.com`, with `MEDIA_SIGNING_KEY` and `MEDIA_PUBLIC_URL`: see [media.md](media.md).
7. Stream app in the EU region, APNs `.p8` key and the Firebase service account uploaded in its push settings
   (chat pushes come from Stream). `FCM_SERVICE_ACCOUNT` in the function secrets: a service account key of the
   production Firebase project (the one of the Android app's production `google-services.json`), the JSON on one
   line; db-events sends Android's pushes with it (`_shared/fcm.ts`), by each token's `platform`.
8. Moderation and support secrets: `DEVICECHECK_KEY_ID` and `DEVICECHECK_PRIVATE_KEY` (an Apple key with
   DeviceCheck; the team comes from `APNS_TEAM_ID`), `DEVICECHECK_ENVIRONMENT=production` (Apple's environment
   is chosen by the project, never by the app), `TWILIO_LOOKUP_API_KEY_SID` and `_SECRET` (a US1 API key,
   required: every verification SMS goes to a mobile line Lookup accepted, and none goes out without it), `SUPPORT_INBOX` (the team's copy of support requests, reports and
   exports it must finish by hand), optionally `EXPORT_MAX_BYTES` (the most one export part weighs, in bytes:
   47185920, 45 MiB, when unset; keep it under the Storage upload limit; anything but a positive whole number
   fails the export), `SUPPORT_INBOUND_SECRET` and `SUPPORT_ADDRESS` ([support.md](support.md#support-by-email)),
   `TURNSTILE_SECRET_KEY` (the Turnstile widget's secret key: required in both projects, the
   signed-out support form is refused without it and `scripts/ci/env-parity.sh` flags a project missing it).
   Otherwise unset, each feature is skipped and logged. The Vault secret `identity_hash_key` is
   created by migration `20260927000004`: never delete or rotate it, every ban and hold mark would be lost.
   The team acts through sophros (`admin_*` functions, audited in `private.admin_audit`).
