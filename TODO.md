# TODO: backend

The app-side list lives in `drafft/TODO.md`.

## Before launch

- [x] **Moderation.** AWS Rekognition in `db-events` (eu-west-1): reject / review / approve, verified in
      production with real photos; `pending` media (borderline labels, images over 5 MB, second reviews
      asked from the app) is reviewed in sophros. Still to do: **full video analysis** (today only the
      poster frame is judged).
- [ ] **Act on flags.** Chat photos are checked silently (`chat-media`) and flagged ones, like refused or
      borderline profile photos, land in `media_flags` (`private.flagged_users`: flags per person over
      30 days). sophros shows them and closes them by hand; still to decide: thresholds and automatic
      actions (warning, shadow limit, ban review).
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
- [ ] **Domain.** `getdrafft.com` is on Cloudflare. Still to do: custom domain `media.getdrafft.com` on the
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
- [ ] **Auth emails** (`auth-email`, Send Email hook; code done). Per environment: a Resend API key,
      Auth > Hooks > Send Email (HTTPS) to `https://<ref>.supabase.co/functions/v1/auth-email`, its secret
      and the key in `functions/.env.<env>` (`SEND_EMAIL_HOOK_SECRET`, `RESEND_API_KEY`, `EMAIL_FROM`),
      `deploy.sh <env> --secrets`, then enable the hook. Auth > Providers > Email: "Confirm email" on, email
      OTP length 6, "Secure email change" off (the app types one code sent to the new address).
- [ ] **Email domain.** Resend only delivers to its own account's address until a domain is verified:
      `mail.getdrafft.com` in Resend, its DNS records in Cloudflare, then `EMAIL_FROM=drafft <no-reply@mail.getdrafft.com>`.
- [ ] **Apple and Google sign-in**, per environment: providers still disabled (see README, "Production setup"
      step 5 and "Staging" step 5).
- [ ] **Phone verification** (`auth-sms`, Send SMS hook; code done). Per environment: Twilio Messaging
      Service (sender "drafft", geo permissions limited to FR BE CH LU GB ES IT DE US CA, SMS pumping
      protection, spend alert), an API key, Auth > Hooks > Send SMS (HTTPS) to `…/functions/v1/auth-sms`,
      its secret and the Twilio values in `functions/.env.<env>`, `deploy.sh <env> --secrets`, then enable
      the hook. Auth > Providers > Phone: "Enable phone confirmations" on (off, Auth sets any number without a
      code), resend interval 30 s, SMS OTP expiry 600 s (the app's `SMS_CODE_LIFETIME`, which
      tells an expired code from a wrong one), SMS rate limit per hour. The app has no switch: it always
      asks for the SMS code, so the hook must be live before any public build.
- [x] **Reports.** Reviewed and closed in sophros (the team's dashboard). A report never holds an account by
      itself: the team decides.
- [ ] **sophros per environment.** Cloudflare Access applications (staging, production), the staff in
      `private.staff` of each database, the Workers' secrets: see the sophros README.
- [ ] **Support replies landing back.** Replies written in sophros are emailed (db-events, `support.reply`)
      with Reply-To SUPPORT_INBOX, so answers reach the team's mailbox, not the thread. Once the domain is on
      Cloudflare: Email Routing for `support@getdrafft.com` to an Email Worker that reads the `[DR-XXXXXX]`
      reference in the subject and posts the message to a `support-inbound` function (shared secret), which
      adds it to `private.support_messages` and reopens the request.
- [ ] **Privacy policy.** Mention device reports (model, iOS, app version, IP and country, for safety;
      `private.ips` kept 180 days after the last open, `private.devices`, last IP included, a year) and staff
      access to conversations when investigating.
- [ ] **Real services end to end.** Verified in production: R2 (HEAD, reject missing, delete), Stream (channel
      on match, openers, users can't create channels). Still to run: sessions, pushes (APNs), media-upload-url
      with a real user token.
- [ ] **Production project** (Ireland; migrations and Vault done, deployed by CI on `v*` tags). Compute Small+, PITR, function secrets without
      `MODERATION_MODE`, Apple and Google auth, R2 bucket + `media.getdrafft.com` + image transformations,
      Stream EU app with the APNs key (see README, "Production setup").
- [x] **Staging project** mirroring production (Supabase branch `staging`), and CI: checks on every pull
      request, deploy to staging on merge to `main`, to production on a `v*` tag, daily drift check.
- [ ] **Update the Supabase CLI** (`brew upgrade supabase`): the Postgres image bundled with 2.90 crashes
      on a denied function call from psql.

## Robustness

- [x] **Dead-letter alert.** Retry budgets per event, circuit breakers per provider, alerts to
      SUPPORT_INBOX (`ops-alert`) and replay or discard from sophros (migration 20260928000121).
- [ ] **Orphan uploads.** A ticket used but never registered leaves an object in R2: lifecycle rule or a
      weekly sweep of keys absent from `profile_media`.
- [ ] **Chat attachments.** Checked silently after delivery (`chat-media`), never removed; not deleted when
      a match ends (they are deleted with the uploader's account).
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
