# drafft-backend

Backend for the drafft iOS app: Supabase (Postgres + PostGIS, Auth, Realtime, Edge Functions) in the EU (Ireland),
Cloudflare R2 for media, Stream for chat, APNs for pushes.

## Architecture

```
iPhone ── PostgREST RPCs ─────────────▶ Postgres (eu-west-1)
   │      Realtime (user:<id> topic) ◀──┤  triggers ─▶ outbox ─pg_net─▶ db-events (Edge Function)
   │                                    │                                 ├─ Stream: channels, openers, session messages
   ├── Edge Functions ──────────────────┤                                 ├─ APNs: match, like, session pushes
   │   stream-token, media-upload-url,  │                                 └─ R2: moderation check, deletions
   │   delete-account                   │
   ├── PUT (presigned) ─▶ R2 ◀── CDN (media.getdrafft.com) ◀── image/video GETs
   └── Stream Chat SDK ─▶ Stream (EU)
```

Principles:

- **One round trip per screen.** Cards are denormalized on write (`profile_cards`), so reading a profile is
  a primary-key lookup. Discover returns a full batch of cards in one call.
- **Writes through RPCs.** Clients can only read their own rows and update whitelisted profile columns. Every
  other write is a `security definer` function that validates input. `anon` can call nothing.
- **Side effects never get lost.** Triggers write to `private.outbox` in the same transaction; pg_net posts
  after commit; pg_cron retries with backoff until `db-events` acks. Handlers are idempotent.
- **Privacy.** Locations are in `private` (not exposed), snapped to ~1 km, and only rounded distances leave
  the database. Birthdates never reach cards. Media stays invisible until moderation approves it.

## Layout

```
supabase/
  migrations/   foundation, profiles, social, sessions, events, purchases, media review, weekly boost, notification settings
  functions/    stream-token, media-upload-url, db-events, delete-account, revenuecat-webhook, stream-webhook, app-config, auth-email, auth-sms, _shared/
  tests/        pgTAP (supabase test db)
  seed.sql      local Vault secrets
docs/matching.md    Discover and matching: eligibility, ranking, likes, boosts, pause, error codes
scripts/bench.sql   latency benchmark on synthetic data
scripts/app-store-products.ts   creates the in-app products in App Store Connect (plan / apply)
```

## API for the app

RPCs (`POST /rest/v1/rpc/<name>`, signed-in user). Errors carry a stable code in `hint`. How Discover picks
and orders cards, and the rules for likes, super likes, boosts and pause: [docs/matching.md](docs/matching.md).

| Area | RPCs |
| --- | --- |
| Onboarding / Edit profile | `PATCH /rest/v1/profiles` (whitelisted columns), `set_sports`, `set_prompts`, `add_profile_media`, `reorder_media`, `delete_media`, `set_location`, `complete_onboarding` |
| Discover | `discover(p_filters, p_limit)`, `swipe(p_target, p_action, p_opener, p_note)`, `undo_last_swipe`, `start_boost` |
| Likes, matches | `liked_me`, `my_matches`, `get_cards(p_ids, p_known)`, `unmatch` |
| Sessions | `propose_session`, `respond_session`, `counter_session`, `cancel_session`, `upcoming_sessions` |
| Safety | `block_user`, `unblock_user`, `blocked_users`, `report_user` |
| Push | `register_push_token`, `unregister_push_token`; `PATCH /rest/v1/profiles` with `language` (en, fr, es, de, it, pt, nl) and the settings `notify_matches`, `notify_likes`, `notify_messages` (mirrored to Stream), `notify_message_previews`, `notify_reactions`, `notify_session_evening`, `notify_session_hour_before`, `notify_weekly_boost` (the app reads them back at launch) |

Realtime: subscribe to the private broadcast channel `user:<your id>`. Events: `like`, `match`,
`match_ended`, `session`, `media`, `wallet` (weekly boost credited: new `boosts` balance).

Reactions: the app sends the emoji itself as the Stream reaction type (`enforce_unique`: one per person per
message) and never on its own messages. Stream's webhook (`scripts/stream-webhook.ts`) calls `stream-webhook`,
which removes self-reactions and pushes "Maya reacted ❤️ to: “…”" to the author, in their language, unless
Messages or Reactions is off; without previews the message text is left out.

drafft tempo's weekly boost: subscribing credits one straight away, then `private.credit_weekly_boosts()`
(pg_cron, every 15 min) adds one each week on `wallets.weekly_boost_at` while premium, and pushes
"Your weekly boost is here" (`kind: weekly_boost`) unless `notify_weekly_boost` is off.

Edge Functions: `stream-token`, `media-upload-url`, `delete-account`, `app-config` (public: `mediaUrl`, where media keys are served from).

Auth emails: Supabase Auth sends none itself. Its Send Email hook calls `auth-email`, which picks the
person's language (`profiles.language`, set at sign-up from the app's `language` metadata) and sends through
Resend: a 6-digit code to confirm sign-up, a new email or a password change (the app types it in), and a
link to reset a forgotten password.

Verification SMS: same for the phone step (sign-up and You, a phone change): the Send SMS hook calls
`auth-sms`, which texts the code through Twilio in the person's language, only to the countries the app
offers. Locally the SMS lands in Mailpit too. Locally
they land in Mailpit (http://127.0.0.1:55424).

## Local development

```sh
cp supabase/.env.example supabase/.env
cp supabase/functions/.env.example supabase/functions/.env   # fill Stream keys to test chat
supabase start            # ports 55420-55429, so it runs next to other Supabase projects
supabase test db          # 37 pgTAP tests
supabase functions serve --env-file supabase/functions/.env
```

Local media: point `R2_ENDPOINT` at the local Storage S3 API (`http://host.docker.internal:55421/storage/v1/s3`,
`R2_REGION=local`, keys from `supabase status`) and create a public `drafft-media` bucket.

Update the CLI (`brew upgrade supabase`): the Postgres image bundled with CLI 2.90 (17.6.1.106) crashes when
a role calls a function it has no EXECUTE on from psql. Tests check privileges with `has_function_privilege`
for that reason. Through the API the same call correctly returns 42501.

### Local database, staging services

The app's **Drafft Local** scheme ("drafft local") runs on this local Supabase while chat, media, pushes,
moderation and purchases go through the staging services:

```sh
supabase start
scripts/local-env.sh     # once: functions/.env.local from .env.staging with local values; yours to edit after
supabase functions serve --env-file supabase/functions/.env.local
# in the app repository: scripts/local-backend.sh (--device for an iPhone on the same Wi-Fi)
```

In `.env.local`, `EMAIL_REAL=true` / `SMS_REAL=true` send auth emails (Resend, your own key if you set one)
and SMS (Twilio) for real instead of to Mailpit. The script never rewrites the file once it exists.

Outgoing calls just work. Incoming webhooks still go to staging, which ignores users it doesn't know
(`ignored: unknown app_user_id`). To credit local purchases, expose the functions with a tunnel
(`cloudflared tunnel --url http://localhost:55421`) and add a **second** webhook in RevenueCat `drafft staging`
to `https://<tunnel>/functions/v1/revenuecat-webhook`, Authorization from
`scripts/local-env.sh --webhook-auth | pbcopy`. Never repoint staging's own webhooks (RevenueCat, Stream).
Local users and media land in Stream staging and `drafft-media-staging`; a `supabase db reset` leaves them
orphaned there.

## Benchmark

`docker exec -i supabase_db_drafft-backend psql -U postgres -v n=50000 < scripts/bench.sql`

50,000 profiles in Île-de-France, viewer with 2,000 past swipes, warm cache, database time only
(add 10 to 80 ms of network for what the phone sees):

| Query | Time |
| --- | --- |
| `discover`, 10 km | ~3 ms |
| `discover`, any distance, 2 sports, age 25-35 | ~55 ms |
| one card by id | ~0.5 ms |
| 20 cards by id | ~1 ms |
| profile edit + card rebuild | ~2 ms |
| discover batch payload | 39 kB for 20 cards |

Building one complete profile the way onboarding does (identity + vitals + icebreaker + voice intro,
3 sports, 3 prompts, 5 photos + 1 video, location, moderation approval, `complete_onboarding`): ~9 ms of
database time over 11 calls. A full card rebuild from scratch: ~0.15 ms. The finished card: 3.5 kB.

Discover walks the location index nearest-first (KNN) and stops once it has enough eligible people, so its
cost doesn't grow with density. The first version filtered and sorted every candidate in the radius:
160 ms on the same data. It takes twice the batch (40 people) so the score can reorder them, which
doubles the walk when filters are narrow; see [docs/matching.md](docs/matching.md#performance).

## Production setup

1. Supabase project `wrcpgnqwjmnirjfxpcux`, **West EU (Ireland)**; compute Small or larger and PITR before the public launch.
2. `supabase link --project-ref <ref> && supabase db push`.
3. `echo production | scripts/sync-vault.sh production` (Vault secrets, from `functions/.env.production`).
4. `supabase secrets set --env-file supabase/functions/.env.production` (see `functions/.env.example`),
   **without** `MODERATION_MODE`. Then `supabase functions deploy`.
5. Auth: Apple (bundle id `so.drafft.app`) and Google (iOS + web client ids) in the dashboard. Send Email hook
   (HTTPS) to `auth-email`: its secret into `SEND_EMAIL_HOOK_SECRET`, with `RESEND_API_KEY` and `EMAIL_FROM`,
   then `deploy.sh production --secrets` before enabling it.
6. R2 bucket `drafft-media` with a custom domain (`media.getdrafft.com`) and Cloudflare image transformations
   enabled on that zone. The app requests sizes with `/cdn-cgi/image/width=800,quality=80/<key>`.
7. Stream app in the EU region, APNs `.p8` key uploaded in its push settings (chat pushes come from Stream).
8. Moderation and support secrets: `DEVICECHECK_KEY_ID` and `DEVICECHECK_PRIVATE_KEY` (an Apple key with
   DeviceCheck; the team comes from `APNS_TEAM_ID`), `TWILIO_LOOKUP_API_KEY_SID` and `_SECRET` (a US1 API key:
   virtual and VoIP numbers get no code), `SUPPORT_INBOX` (the team's copy of support requests, reports and
   export requests). Unset, each feature is skipped and logged. The Vault secret `identity_hash_key` is
   created by migration `20260927000004`: never delete or rotate it, every ban and hold mark would be lost.
   The team acts with `set_moderation(user, 'review' | 'selfie' | 'banned' | null, note)` and
   `review_media(media, approved)`, service role only.

## Staging

A persistent Supabase branch named `staging` of `drafft-backend` (its own database, Auth, Storage, Edge
Functions, keys and URL), fed with the same migrations. The app's **Drafft Staging** scheme points at it
(`drafft β` on the home screen, same bundle id as production). Everything goes to staging first:
`scripts/deploy.sh staging`, check, then `scripts/deploy.sh production`.

GitHub Actions (`.github/workflows/backend.yml`) does it on its own: every pull request is checked
(Deno type checks, database tests), a push to `main` deploys to staging, and a `v*` tag deploys to
production (the `production` environment only accepts `v*` tags). Migrations and functions only:
secrets are still set by hand with `deploy.sh <env> --secrets`.

| | Production | Staging |
|---|---|---|
| Supabase | `wrcpgnqwjmnirjfxpcux` | branch `staging` (ref in `scripts/deploy.sh`) |
| Edge Functions secrets | `functions/.env.production` | `functions/.env.staging` |
| R2 bucket (EU jurisdiction) | `drafft-media` | `drafft-media-staging` |
| Public media URL (until the domain) | `pub-f4b77604ea6f42188c3ba8da914a6a16.r2.dev` | `pub-2877e6f189f0420785f5cd685f44f789.r2.dev` |
| Stream | app `drafft` (EU) | app `drafft-staging` (EU) |
| RevenueCat | project `drafft` (`proj3dc1aebd`) | project `drafft staging` (`proje5eb803d`), same catalog |
| APNs, Rekognition | shared (same bundle id, same key) | shared |
| DeviceCheck key | shared (the app picks Apple's development or production DeviceCheck) | shared |

Setting it up once:

1. `supabase branches create staging --persistent --region eu-west-1`, then its ref and publishable key into
   `scripts/deploy.sh` and the app's `Config/Staging.xcconfig`.
2. `scripts/deploy.sh staging`.
3. `functions/.env.staging` from `.env.example`: same APNs and Rekognition values as production; its own
   R2 token (bucket `drafft-media-staging`, EU), `R2_BUCKET=drafft-media-staging`,
   `R2_ENDPOINT=https://<account>.eu.r2.cloudflarestorage.com` (EU jurisdiction buckets only answer there),
   `MEDIA_PUBLIC_URL=https://pub-2877e6f189f0420785f5cd685f44f789.r2.dev`, the Stream staging app's keys,
   and fresh random `DB_EVENTS_SECRET` and `REVENUECAT_WEBHOOK_AUTH` (`openssl rand -hex 32`). Then
   `scripts/deploy.sh staging --secrets`. Wrangler needs `--jurisdiction eu` to see either bucket.
4. `scripts/sync-vault.sh staging`: the database's Vault secrets (`edge_functions_url`, `db_events_secret`
   from `DB_EVENTS_SECRET`), so database events reach the functions. Run it again whenever `DB_EVENTS_SECRET`
   changes, in either environment.
5. Auth on the branch: redirect URLs `drafft://auth-callback` and `drafft://auth-callback/reset`, Apple and
   Google (same client ids as production), Send Email hook to its `auth-email` (its own secret and Resend key).
6. Stream staging app (EU), configured by script like production, `--env-file=supabase/functions/.env.<env>`:
   `stream-settings.ts` (app settings, grants), `stream-push.ts` (APNs providers from `APNS_*`),
   `stream-webhook.ts` (with `SUPABASE_URL` for staging). `stream-diff.ts` compares the two apps.
7. RevenueCat project `drafft staging`: same apps, products, entitlement and offerings as `drafft`
   (identifiers included), App Store Connect API key and In-App Purchase key uploaded, webhook →
   staging `revenuecat-webhook` with `REVENUECAT_WEBHOOK_AUTH` as its Authorization header. Any catalog
   change goes to both projects. Its public SDK key is in the app's `Config/Staging.xcconfig`.
8. App Store Server Notifications (V2): production URL → RevenueCat `drafft`, sandbox URL → RevenueCat
   `drafft staging` (`scripts/app-store-notifications.ts`). Production TestFlight builds buy in the
   sandbox, so their server notifications go to staging; their SDK still syncs on launch.

## Not done yet

See [TODO.md](TODO.md).
