# TODO: backend

The app-side list lives in `drafft/TODO.md`.

## Before launch

- [x] **Moderation.** AWS Rekognition in `db-events` (eu-west-1): reject / review / approve, verified in
      production with real photos. Still to do: a **review queue** for `pending` media (borderline labels,
      images over 5 MB, second reviews asked from the app: `review_requested_at`), and **full video
      analysis** (today only the poster frame is judged).
- [ ] **Act on flags.** Chat photos are checked silently (`chat-media`) and flagged ones, like refused or
      borderline profile photos, land in `media_flags` (`private.flagged_users`: flags per person over
      30 days). Decide thresholds and actions (warning, shadow limit, ban review) and a metrics view.
- [x] **Purchases (server side).** App Store Connect products (`scripts/app-store-products.ts`), RevenueCat
      project `proj3dc1aebd` (App Store app, 9 products, entitlement `drafft_tempo`, offering `default`,
      keys validated), webhook → `revenuecat-webhook` → `apply_purchase_event`, test event received.
      Still to do: a **sandbox purchase end to end** once the app has the SDK, and a **review screenshot**
      per product in App Store Connect before the first submission.
- [ ] **Apple Developer membership** renews before 10 May 2027, or the paid apps agreement lapses and
      purchases stop.
- [ ] **Premium gating on the server.** `liked_me` returns identities to everyone. If "see who liked you" is
      a Plus feature, blur or withhold server-side for free accounts, not only in the UI.
- [ ] **Remaining likes.** Expose the daily count (`my_limits()` RPC: likes left, super likes, boosts,
      boost end, premium) so the app shows what the server enforces.
- [ ] **Domain.** Buy the domain, add it to Cloudflare, then: custom domain `media.<domain>` on the
      `drafft-media` bucket, cache rule (1 year, keys are immutable), Image Transformations on the zone,
      `MEDIA_PUBLIC_URL` secret switched, r2.dev URL disabled. Also needed for auth emails, Site URL,
      Universal Links, privacy policy.
- [ ] **Stream plan.** Current plan: 1,000 MAU and 100 concurrent connections. Enough for the beta, not
      for the public launch.
- [x] **APNs.** Key `F98686ASM4` (Sandbox & Production, `~/Secrets/drafft/apns`): Supabase secrets set and
      verified end to end (db-events → Apple → dead token pruned); Stream push providers `drafft-apn`
      (production) and `drafft-apn-dev` (sandbox).
- [ ] **Push texts.** `db-events` pushes are in English with a generic title, except `boost.weekly`. `profiles.language`
      exists now, and the settings (`notify_*`, checked by db-events, messages mirrored to Stream); use the app's `NotificationText` sentences (7 languages),
      and send `sender name` + `photo key` in the payload so the app's service extension shows the
      sender's photo as the icon. Decide whether like pushes name the liker (today: anonymous, because
      "see who liked you" may be a paid feature).
- [ ] **Auth emails.** Without custom SMTP, Supabase only emails members of the organization, a few per
      hour: beta testers get no confirmation email. Resend (or Postmark) + custom SMTP in Auth settings.
- [ ] **Email codes on the hosted project.** The app changes email and password with a 6-digit code:
      in Auth > Emails, paste `supabase/templates/email_change.html` and `reauthentication.html`
      (they show `{{ .Token }}`), and turn "Secure email change" off (`double_confirm_changes = false`).
- [ ] **Apple and Google sign-in** (providers disabled for now; see README, "Production setup").
- [ ] **Phone verification.** SMS provider for Supabase Auth phone OTP (Twilio, MessageBird, Vonage),
      then `BackendConfig.smsEnabled = true` in the app (sign-up and You use `phone_change`).
- [ ] **Reports.** Review tool (or Studio saved queries) and process; automatic hide after N reports.
- [ ] **Real services end to end.** Verified in production: R2 (HEAD, reject missing, delete), Stream (channel
      on match, openers, users can't create channels). Still to run: sessions, pushes (APNs), media-upload-url
      with a real user token.
- [ ] **Production project** (Ireland, linked; migrations and Vault done). Compute Small+, PITR, function secrets without
      `MODERATION_MODE`, Apple and Google auth, R2 bucket + `media.drafft.so` + image transformations,
      Stream EU app with the APNs key (see README, "Production setup").
- [ ] **Staging project** mirroring production, and CI: `supabase test db` + `deno check` + `deno lint` on
      every push, `supabase db push` on merge.
- [ ] **Update the Supabase CLI** (`brew upgrade supabase`): the Postgres image bundled with 2.90 crashes
      on a denied function call from psql.

## Robustness

- [ ] **Dead-letter alert.** Outbox rows with `attempts >= 10` and no `delivered_at` need an alert
      (pg_cron job posting to Slack or email) and a replay procedure.
- [ ] **Orphan uploads.** A ticket used but never registered leaves an object in R2: lifecycle rule or a
      weekly sweep of keys absent from `profile_media`.
- [ ] **Chat attachments.** Not moderated; not deleted when a match ends (they are deleted with the
      uploader's account).
- [ ] **Rate limits.** Per-user limits on media-upload-url, report_user and swipe bursts; review Auth rate
      limits in `config.toml`.
- [ ] **Monitoring.** Sentry for Edge Functions; weekly `pg_stat_statements` review; alert on slow
      `discover`.

## Privacy (GDPR)

- [ ] Data export (right of access): an Edge Function that bundles the profile, media keys, swipes,
      matches, sessions and Stream messages.
- [ ] Retention: purge `swipes` passes older than N months, delivered outbox rows (done, 7 days), handled
      reports after the legal period.
- [ ] Data processing agreements: Supabase, Cloudflare, Stream, moderation and SMS providers.

## Scale, when numbers ask for it

- [ ] `discover` without a distance limit and with narrow filters walks far (~30 ms at 50k profiles):
      cap the walk, or precompute a per-user candidate queue.
- [ ] Read replica for Likes/Matches reads; analytics export (PostHog or ClickHouse) instead of queries
      on the primary.
