# drafft-backend

Backend for the drafft iOS app: Supabase (Postgres + PostGIS, Auth, Realtime, Edge Functions) in the EU (Ireland),
Cloudflare R2 for media, Stream for chat, APNs (iPhone) and FCM (Android) for pushes.

## Architecture

```
iPhone ── PostgREST RPCs ─────────────▶ Postgres (eu-west-1)
   │      Realtime (user:<id> topic) ◀──┤  triggers ─▶ outbox ─pg_net─▶ db-events (Edge Function)
   │                                    │                                 ├─ Stream: channels, openers, session messages
   ├── Edge Functions ──────────────────┤                                 ├─ APNs, FCM: match, like, session pushes
   │   media-upload-url, chat-media,    │                                 └─ R2: moderation check, deletions
   │   delete-account, device-check,    │
   │   support, app-config, stream-token│
   ├── PUT (presigned) ─▶ R2 (private) ◀── media Worker + CDN (media.getdrafft.com) ◀── signed GETs
   └── Stream Chat SDK ─▶ Stream (EU)
```

Principles:

- **One round trip per screen.** Cards are denormalized on write (`profile_cards`), so reading a profile is
  a primary-key lookup. Discover returns a full batch of cards in one call.
- **Writes through RPCs.** Clients can only read their own rows and update whitelisted profile columns. Every
  other write is a `security definer` function that validates input. `anon` executes no database function;
  it reads `sports` and calls the public Edge Functions `app-config` and `support`.
- **Side effects never get lost.** Triggers write to `private.outbox` in the same transaction; pg_net posts
  after commit; pg_cron retries with exponential backoff and jitter, within a budget per event (~24 h,
  `private.outbox_policies`), until `db-events` acks. A provider that's down (Stream, APNs, Resend, Twilio,
  R2) opens its circuit breaker: its events wait without spending attempts. Stale pushes are skipped. An
  event out of budget lands in the dead-letter queue, alerts the team (`ops-alert`: one email per incident, a
  reminder after an hour, a daily summary) and waits for an admin to replay or discard it in sophros.
  Handlers are idempotent and record each side effect done (`steps`), so a retry or replay runs only what's
  missing.
- **Privacy.** Locations are in `private` (not exposed), snapped to ~1 km, and only rounded distances leave
  the database. Birthdates never reach cards. Profile photos and videos stay invisible until moderation
  approves them and their owner saves them: the app registers a picked photo as a draft
  (`add_profile_media(p_draft => true)`), moderated at once but never on a card, and publishes it with
  `save_profile_media` (Save in Edit profile, the end of sign-up), which also keeps a live profile's
  portrait (`portrait_required`); the voice intro isn't moderated and reaches cards as soon as it's set, and chat photos and
  videos are delivered first, then checked silently (`chat-media`).

## Layout

```
supabase/
  migrations/   foundation, profiles, social, sessions, events, purchases, media review, weekly boost, notification settings
  functions/    stream-token, media-upload-url, chat-media, db-events, ops-alert, delete-account, device-check, support, support-inbound, revenuecat-webhook, purchase-sync, phone-code, stream-webhook, app-config, auth-email, auth-sms, _shared/
  tests/        pgTAP (supabase test db)
  seed.sql      local Vault secrets
cloudflare/media-worker/          serves the private R2 bucket through signed links
cloudflare/support-mail-worker/   Email Worker: mail to the support address back into sophros (Support by email)
docs/matching.md    Discover and matching: eligibility, ranking, likes, boosts, pause, error codes
scripts/bench.sql   latency benchmark on synthetic data
scripts/app-store-products.ts   creates the in-app products in App Store Connect (plan / apply)
```

## API for the app

RPCs (`POST /rest/v1/rpc/<name>`, signed-in user). Errors carry a stable code in `hint`. How Discover picks
and orders cards, and the rules for likes, super likes, boosts and pause: [docs/matching.md](docs/matching.md).

| Area | RPCs |
| --- | --- |
| Onboarding / Edit profile | `accept_terms(p_version, p_sensitive_consent)`, `PATCH /rest/v1/profiles` (whitelisted columns), `set_sports`, `set_prompts`, `add_profile_media(…, p_draft)`, `save_profile_media(p_ids, p_removed)`, `reorder_media`, `delete_media`, `set_location`, `area_at(p_lat, p_lng)`, `complete_onboarding` |
| Discover | `discover(p_filters, p_limit)`, `swipe(p_target, p_action, p_opener, p_note)`, `undo_last_swipe`, `start_boost` |
| Likes, matches | `liked_me`, `my_matches`, `get_cards(p_ids, p_known)`, `unmatch` |
| Sessions | `propose_session`, `respond_session`, `counter_session`, `cancel_session`, `upcoming_sessions` |
| Safety | `block_user`, `unblock_user`, `blocked_users`, `report_user`, `report_app_open(p_install, p_device)` (each time the app comes to the front: install id, model, iOS, app version, locale, time zone; the IP and country come from the request) |
| Moderation | `request_media_review(p_media)` (a second look at a refused photo), `submit_selfie(p_path)` (after uploading the selfie to the private Storage bucket `verification-selfies`, in the person's own folder, while a selfie is asked) |
| Your data | `request_data_export()` (one open request at a time; the export is emailed as one or more links, see Data export below) |
| Push | `register_push_token`, `unregister_push_token`; `PATCH /rest/v1/profiles` with `language` (en, fr, es, de, it, pt, nl) and the settings `notify_matches`, `notify_likes`, `notify_messages` (mirrored to Stream), `notify_message_previews`, `notify_reactions`, `notify_session_evening`, `notify_session_hour_before`, `notify_weekly_boost` (the app reads them back at launch) |

Area: `area_at(p_lat, p_lng)` answers with the area a blurred position falls in, `{"name", "city"}`
("Paris 11", "Lyon 4", "Annecy"), or the nearest one within 3 km, or null (outside France, or areas not
loaded); the app then falls back to its own resolver. Nothing is stored. The areas (`private.areas`) are every
commune of France, Paris, Lyon and Marseille by arrondissement, from Etalab's boundaries (Licence Ouverte),
loaded by `scripts/load-areas.ts`, which `deploy.sh` runs: it loads only when codes or names differ from the
source. Bump its `YEAR` once a year. Error: `invalid_location`.

Terms and consent: gender and the genders someone wants to see can reveal their sexual orientation, lifestyle
answers their health or beliefs, so drafft processes them on explicit consent, asked in its own step and recorded
on the server. `accept_terms(p_version, p_sensitive_consent)` records, for the caller, the terms version the app
showed (`profiles.terms_version`, an ISO date `YYYY-MM-DD`, and `terms_accepted_at`) and, when
`p_sensitive_consent` is true, `sensitive_consent_at`; the owner reads the three columns, only this RPC writes
them. Every accepted call is also appended to `private.consent_events` (version, whether it gave the consent,
when), which the export includes. Errors: `unauthenticated`, `not_found` (also for an account deleted and kept
for safety), `invalid_terms_version` (not a `YYYY-MM-DD` date, or older than the version on record),
`sensitive_consent_required` (false or null while no consent is on record, onboarded or not: there is no account
without a gender). With a consent on record, false or null records the terms alone: it never withdraws the
consent. `complete_onboarding` needs both (`terms_required`, after `phone_required`). Accounts onboarded before
stay valid: the app asks at its next open (a `terms_version` behind its own, or no `sensitive_consent_at`).
Withdrawing the consent is deleting the account (`delete-account`); lifestyle answers can be cleared on their own.
The columns and the log live with the profile: erased with it, or kept with it when the account is kept for safety.

Likes: with drafft tempo `liked_me` returns full cards; a free account gets per like only
`{likeId, superLike, likedAt, thumbhash, blurUrl}` (no id, name, age, key or sharp URL, and `get_cards` refuses
its likers). `thumbhash` is the first photo's placeholder; `blurUrl` is a signed link of about an hour to a
blurred copy of that photo (200 px wide, strong blur, WebP without metadata), or null without a photo, when the
caller is on hold, or without the Vault secrets. Show the ThumbHash, then the blurred image once loaded; read
`liked_me` again for fresh links. See the media Worker below for what the link can and cannot open.

Realtime: subscribe to the private broadcast channel `user:<your id>`. Events: `like`, `match`,
`match_ended`, `session`, `media`, `wallet` (any change to your wallet: purchase, refund, weekly boost,
`start_boost`, super like, undo, premium starting or ending, RevenueCat transfer; the payload is the whole balance:
`super_likes`, `boosts`, `boost_ends_at`, `premium_until`, `weekly_boost_at`), `moderation`
(the account's hold changed: `{ state }`, null once lifted).

RevenueCat `TRANSFER` (restore on another drafft account): `premium_until` moves from the `transferred_from`
accounts to the `transferred_to` ones; consumables already credited stay with the account that bought them.

Reactions: the app sends the emoji itself as the Stream reaction type (`enforce_unique`: one per person per
message) and never on its own messages. Stream's webhook (`scripts/stream-webhook.ts`) calls `stream-webhook`,
which removes self-reactions and pushes "Maya reacted ❤️ to: “…”" to the author, in their language, unless
Messages or Reactions is off; without previews the message text is left out.

drafft tempo's weekly boost: subscribing credits one straight away, then `private.credit_weekly_boosts()`
(pg_cron, every 15 min) adds one each week on `wallets.weekly_boost_at` while premium, and pushes
"Your weekly boost is here" (`kind: weekly_boost`) unless `notify_weekly_boost` is off.

Edge Functions (signed in unless noted):

| Function | Use |
| --- | --- |
| `media-upload-url` | a presigned R2 upload URL for a photo, video or voice intro |
| `chat-media` | silent check of a photo or video sent in a chat (`{ flagged }`, nothing changes for either person) |
| `delete-account` | deletes the account, its chats, media, selfies and data exports, or keeps it for safety (erased later by db-events `account.purge`) |
| `device-check` | the iPhone's DeviceCheck token, at each launch and sign-in |
| `phone-code` | texts a code to verify a number: email confirmed, limits per number, account and IP, Twilio Lookup (mobile lines only, fails closed) |
| `purchase-sync` | credits a purchase or restore straight away from RevenueCat (see Purchases below) |
| `support` | public: every "Get help" and "Contact us" form, signed in or not (`{ reference }`) |
| `support-inbound` | not for the app: the support mail Worker posts each email the support address receives (shared secret, see Support by email) |
| `app-config` | public: `mediaUrl`, where media keys are served from (links themselves come signed) |
| `stream-token` | a Stream Chat token (for the chat, not wired in the app yet) |

Purchases: `POST /functions/v1/purchase-sync` (signed in, body `{ "transaction_id": "<App Store transaction id>" }`
or empty), right after a purchase or a restore, reads the caller's purchases from RevenueCat's REST API v2 and
answers `{ wallet, transaction }`: `wallet` is the updated balance (`super_likes`, `boosts`, `boost_ends_at`,
`premium_until`, `weekly_boost_at`), so the credit doesn't wait for the webhook; `transaction` is
`{ id, credited }` for the transaction asked about (`null` without one). The app trusts `credited`: true once
that consumable is credited to the caller and not refunded, or that subscription is owned and premium is active.
Consumables are credited once per App Store transaction (`private.purchase_credits`, shared with
`revenuecat-webhook`, which stays the safety net); `premium_until` is copied from the active `drafft_tempo`
entitlement. Only the project's store environment counts (`purchase_environment`). Errors: 429
`too_many_requests` (1 call per 5 s, 30 per hour and account), 503 `sync_not_configured` (secrets missing),
503 `sync_unavailable` (RevenueCat unreachable; the webhook still credits).

Support form (`POST /support { topic, message, language, email?, context?, turnstileToken? }` → `{ reference }`):
signed in, the reply goes to the account's email and no captcha is asked. Signed out, `turnstileToken` (a
Cloudflare Turnstile token for `getdrafft.com`, at most 2048 characters) is checked server side against
Siteverify with the `TURNSTILE_SECRET_KEY` function secret. Error codes: `captcha_required` (400, no token),
`captcha_failed` (403, refused by Cloudflare or issued for another hostname), `captcha_not_configured` (500,
hosted project without the secret: signed-out requests are refused and logged; locally the check is skipped with
a warning), plus `invalid_topic`, `invalid_message`, `invalid_email` (400) and `too_many_requests` (429).

Auth emails: Supabase Auth sends none itself. Its Send Email hook calls `auth-email`, which picks the
person's language (`profiles.language`, set at sign-up from the app's `language` metadata) and sends through
Resend: a 6-digit code to confirm sign-up, a new email or a password change (the app types it in), and a
link to reset a forgotten password.

Verification SMS: same for the phone step (sign-up and You, a phone change): the Send SMS hook calls
`auth-sms`, which texts the code through Twilio in the person's language, only to the countries the app
offers. Locally both land in Mailpit (http://127.0.0.1:55424), unless `EMAIL_REAL=true` or `SMS_REAL=true`
in `.env.local` sends them for real.

## sophros, the team's dashboard

Moderation and support run in [sophros](../sophros), its own repository: one Cloudflare Worker per
environment behind Cloudflare Access. It reaches the database with the secret key, only through the
`admin_*` functions (`20260927000007_sophros.sql`, service role only). Each call names the staff member;
the database checks their role in `private.staff` (`support`, `moderator`, `admin`) and writes
`private.admin_audit`, which can't be edited or deleted. Staff are per database:

```sql
insert into private.staff (email, role) values ('someone@getdrafft.com', 'admin');
```

Locally, `supabase db reset` seeds `dev@drafft.local` (admin), the identity sophros uses in dev mode.

Support replies are written in sophros (`admin_reply_support`) and emailed by db-events (`support.reply`),
framed in the person's language, with Reply-To the support address (`SUPPORT_ADDRESS`, SUPPORT_INBOX while it is
unset), like every email to a member about their account (notices, statements of reasons, exports): a reply comes
back to the team. The mailer never sends to reserved domains (`.test`, `.example`, `.invalid`, `.localhost`), which
the demo and test accounts use.

### Support by email

Every support email a member gets, the acknowledgement (`support.created`) and the team's replies
(`support.reply`), has the request's reference at the end of its subject (`We got your message [DR-ABC234]`,
`Re: Help [DR-ABC234]`). Every email to a member about their account has Reply-To `SUPPORT_ADDRESS`
(support@getdrafft.com; while it is unset, SUPPORT_INBOX). The team's copies still go to SUPPORT_INBOX. What comes
back, or anything else written to that address, lands in sophros (migration `20260930000501`):

1. Cloudflare Email Routing hands the email to the Email Worker `cloudflare/support-mail-worker`. It parses it
   (postal-mime), keeps what the person wrote this time (quoted history, `>` lines and signature cut off; an
   HTML-only email, or an empty text part next to HTML, as text), the attachments' names only, and the reference
   (`DR-XXXXXX` in the subject, else in the quoted text, HTML quotes included). The sender is the envelope's (SMTP
   MAIL FROM), never the From header. It is **verified** only when Cloudflare's own Authentication-Results (the
   first such header, authserv-id `mx.cloudflare.net`) say SPF passed for the envelope's domain, or DKIM passed
   for a domain aligned with it.
2. It posts that to `support-inbound` with the header `x-support-inbound-secret` (`SUPPORT_INBOUND_SECRET`, the
   same in the Worker and the function). Both sides parse the payload and the answer with
   `supabase/functions/_shared/support_inbound.ts` (a wrong type is a 400, never coerced), and the function keeps
   the request's context within its 2000 bytes. `receive_support_email`:
   - verified, a known reference, from the address its request was written from (or its account's current
     email): the message joins the request as the member's (`support_messages.direction = 'in'`, at most 8000
     characters), the request reopens, and db-events emails the team a copy (`support.received`, to SUPPORT_INBOX);
   - verified, anything else: a new request from the sender, linked to the account with that email if any (its
     language, else English), acknowledged, the team copied;
   - not verified: always a new request, linked to no account, never acknowledged (no mail to an address that may
     not have written); the team copy says so. A reference it mentioned is kept in its context for the team.
     Another address never joins someone else's thread.
   - the topic is the cleaned subject (no `Re:`, no reference), else "Message by email" in the account's
     language; each email once (by Message-ID, `private.support_inbound`); 10 messages an hour into one request,
     5 new requests an hour per address and 200 in all (their own limits, apart from the app's signed-out
     form); posts over 256 KB refused.
3. Nothing is lost: when the function doesn't take the email (unreachable, 4xx, 5xx, an answer that isn't a
   result), or it isn't a person writing (an auto-reply, a bounce, a mailing list: never filed, so an
   out-of-office can't open request after request), the Worker forwards the whole email to `FALLBACK_ADDRESS`
   (the team's mailbox) with an `X-Drafft-Support` header saying why. Filed but not whole (attachments, a text
   cut to size, lines of their own cut with the quoted history, since "he wrote:" reads like an attribution):
   filed, and forwarded as well. If even that forward fails, the Worker throws and Email Routing refuses the
   email, so the sender's server reports it.

`admin_support` returns each message's `direction`; showing the member's messages as received by email is
sophros' part (its own pull request). Until then they read like the team's.

A team reply is never left "Sending" (`sent_at` and `error` both null): whatever stops db-events from sending it,
reading it included, is recorded on the message (`error`) and retried, and a reply the outbox gives up on (out of
budget, or discarded) is marked failed when nothing was recorded (`private.support_reply_given_up`). A replay
that sends it clears the error.

Setting it up, per environment (production: support@getdrafft.com; staging: support-staging@getdrafft.com):

1. Function secrets, in both projects (the drift check wants the same names): `SUPPORT_INBOUND_SECRET`
   (`openssl rand -hex 32`, one per environment). Leave `SUPPORT_ADDRESS` unset for now: replies keep going to
   SUPPORT_INBOX until the route works.
2. Merge: CI deploys the migration and `support-inbound`.
3. Cloudflare, zone `getdrafft.com` › Email › Email Routing: enable it. It adds its MX records
   (`route1/2/3.mx.cloudflare.net`), a DKIM record and an SPF TXT record
   (`v=spf1 include:_spf.mx.cloudflare.net ~all`); the zone's current `v=spf1 -all` has to give way (one SPF
   record per name). The apex has no MX today and `mail.getdrafft.com` (Resend's sending subdomain, MX to Amazon
   SES) is not affected.
4. Destination addresses: add the team's mailbox (SUPPORT_INBOX) and confirm the email Cloudflare sends it
   (a Worker can only forward to a verified address).
5. The Worker, from `cloudflare/support-mail-worker`: `npm ci`, then per environment
   `npx wrangler@4 secret put SUPPORT_INBOUND_SECRET --env <env>` (the function's value) and
   `npx wrangler@4 secret put FALLBACK_ADDRESS --env <env>` (the verified mailbox), then
   `npx wrangler@4 deploy --env <env>`.
6. Email Routing › Routing rules: a custom address `support@getdrafft.com` (and `support-staging@`), action "Send
   to a Worker", `drafft-support-mail` (and `drafft-support-mail-staging`). Leave the catch-all off.
7. Try it on staging: send an email to support-staging@getdrafft.com from the address of a staging request,
   with its `[DR-XXXXXX]` in the subject (Reply-To is still SUPPORT_INBOX at this point, so a plain reply would
   go there): the message shows in sophros and the request reopens. Then set `SUPPORT_ADDRESS`
   (`support-staging@getdrafft.com` on staging, `support@getdrafft.com` in production) in both projects: from
   then on, replies come back through this route.

### Statements of reasons (DSA art. 17)

When a person on the team refuses a photo, removes a message, puts an account on hold or bans it, the member is
told what was decided and why (migration `20260930000401`): the decision is stored in
`private.moderation_decisions` (kept like the moderation log: 1 year, 3 about a banned account, even once it is
erased) and db-events (`moderation.decision`) emails it in their language: the reason, the section of the terms of
use it falls under with a link to it (`https://getdrafft.com/<lang>/terms#community`, `#eligibility`,
`#moderation`, or the terms as a whole for `other`), the team's note if any, and how to contest it (the in-app help
center, or a reply, reviewed by someone else). It is pushed when no other push says it (a removed message, a
review, a ban; a refused photo and a selfie request have their own); without an email address on the account the
push doesn't point to one, and the missing email is logged. A photo refused by a person gets this statement as its
only email. A removed message is told once Stream shows it removed (a 404 or code 16 counts as removed). Automatic
decisions (the photo check, holds from a device or a link to a banned account) keep their own messages. The
statements are part of the member's data export.

The contract for sophros (it must ship before this, see Breaking changes in the pull request):

| RPC (service role) | New parameters | Statement sent |
| --- | --- | --- |
| `admin_set_hold(p_actor, p_user, p_state, p_reason, p_category, p_details)` | reason category, note for the member | a hold put or changed: `account_review`, `account_selfie`, `account_banned`; a selfie asked again with a category (the state stays `selfie`): `account_selfie`, pushed as a selfie request; none when lifted, or unchanged otherwise |
| `admin_review_media(p_actor, p_media, p_approved, p_reason, p_category, p_details)` | same | `photo_refused`, when a photo becomes refused |
| `admin_decide_photo(p_actor, p_media, p_reason, p_hold, p_hold_reason, p_category, p_details)` | same, for the photo and the hold | `photo_refused` for a pending photo, plus the hold's |
| `admin_close_report(p_actor, p_report, p_resolution, p_hold, p_category, p_details)` | same, for the hold | the hold's |
| `admin_decide_flags(p_actor, p_ids, p_reason, p_hold, p_hold_reason, p_category, p_details)` | same, for the hold | the hold's |
| `admin_log(p_actor, 'message.delete', p_user, '<match>/<message>', p_reason, p_override, p_category, p_details, p_override_basis)` | same; `p_user` is the author, one of the two members | `message_deleted` |

`p_reason` stays the team's internal reason (audit log, moderation log); `p_details` is written for the member
and sent as written. Both are checked once, before anything applies: `p_category` must be one of
`admin_reason_categories(p_actor)` → `[{ id, termsAnchor }]` (`harassment`, `hate`, `sexual_content`,
`violence_illegal`, `underage`, `impersonation`, `scam_commercial`, `privacy`, `fake_account`, `evasion`,
`photo_guidelines`, `identity_check`, `other`), else `invalid_category`; a decision that sends a statement needs
one (`category_required`); a note over 1,000 characters fails with `details_too_long` (never cut). The audit log
records the category. A removal needs `<match id>/<message id>` and its author among the two members
(`invalid_target`).

### Reading conversations and selfies

`admin_log(p_actor, 'conversation.view', p_user, p_match, p_reason, p_override, …, p_override_basis)` is the gate
sophros calls before reading a conversation from Stream (and `'message.delete'` before removing a message). It needs
a reason written by the person (`reason_required`; the old default "opened in sophros" is refused) and a basis,
from `admin_conversation_access(p_actor, p_match)` → `{ basis: ('report' | 'support' | 'hold')[], canOverride }`
(`not_found` for an unknown match): `report` (a report between the two members), `support` (a help request from
either, open or from the last 90 days), `hold` (either account on hold or banned, unless the reader put that hold
themself). Without one it fails with `no_basis`; an admin may still read it with `p_override = true` and
`p_override_basis` (`legal_request` or `member_safety`, else `override_basis_required`), for a legal request or
members' safety only; the audit log records the override and why. The audit log records the basis.
`admin_selfies(p_actor, p_user, p_reason)` needs a reason (no default any more).

## Privacy and data retention

What drafft keeps about people, where, for how long, and what enforces it, as the privacy policy promises
("How long we keep it"). The periods are maximums: most rows go earlier, with their account. Daily jobs run
from pg_cron; `private.purge_expired()` (`privacy-purge`, migration `20260930000101`) takes every period from
`private.retention_period` and records what each step deleted in `private.job_runs`.

| Data | Where | Kept | Enforced by |
| --- | --- | --- | --- |
| Account, profile, lifestyle, sports, prompts, settings, location, wallet, cards, swipes, matches, blocks, sessions, push tokens, DeviceCheck token, selfie records, export requests, terms and consent log | `auth.users`, `auth.identities`, `public.*`, `private.locations`, `private.device_checks`, `private.selfie_checks`, `private.data_requests`, `private.consent_events` | the account's life | `delete-account`: deleting the Auth user cascades through these tables (purchases, photo flags, help requests and reports' reporter are unlinked instead, `on delete set null`) |
| Photos, videos, voice intro, chat photos and videos | R2 `u/<id>/…` | the account's life; a removed photo at once | `delete-account` (the whole prefix), db-events `media.deleted` |
| Profile photos picked but never saved (drafts) | `public.profile_media` (`published_at` null), R2 `u/<id>/…` | deleted by the app when the person leaves without saving; 7 days at most | `media-drafts-purge` (`private.purge_media_drafts()`), db-events `media.deleted` |
| Chat messages, and the chat photos, videos and voice messages they point to | Stream, one channel per match; R2 `u/<id>/chat/…` | the match's life; an ended match's chat is frozen, then erased 1 year after the match ended | `delete-account` erases its chats and hard-deletes the Stream user; db-events `chat.erase` (below) |
| Accounts kept for safety (banned, held or under an open report when deleted) | the same rows, `profiles.deleted_at`, `private.account_deletions` | 1 year after the case is closed | db-events `account.purge` (below) |
| Verification selfies | Storage `verification-selfies` | until the check is over; a banned account's 6 months, for an appeal | db-events `selfie.delete`, `selfie.expired` (below), `delete-account` |
| Data export archives | Storage `data-exports` | 7 days; at once when the account is deleted | `data-exports-expire`, `data-exports-sweep`, `delete-account` (see Data export below) |
| Deletions asked for without the app (where to confirm, the outcome) | `private.staff_deletions` | until the confirmation is sent (the addresses), 30 days (the row); the audit log keeps what was done | `staff-deletions-cleanup` (see Deleting an account without the app below) |
| IP addresses | `private.ips` | 180 days after the last open from that address | `device-reports-prune` |
| Sign-in events with IP addresses | `auth.audit_log_entries` | not enforced yet | see the workspace [TODO.md](../TODO.md) |
| Devices (model, versions, last IP) | `private.devices` | 1 year after the last open | `device-reports-prune` |
| Verification texts sent (number, IP) | `private.sms_sends` | 30 days | `sms-sends-cleanup` |
| Sending queue (pushes, emails, Stream and R2 calls) | `private.outbox` | delivered 7 days; dropped, discarded or failed 30 days, except a failed erasure, kept until the team replays or discards it | `outbox-cleanup` (`private.outbox_cleanup()`) |
| Session reminders queued | `private.session_reminders` | the session's life | `on delete cascade` from the session |
| Purchase sync calls (rate limit) | `private.purchase_sync_calls` | 1 hour, trimmed at the member's next sync; the account's life at most | `purchase_sync_begin`, `on delete cascade` |
| Team alerts (counts only, nothing personal), job runs | `private.ops_alerts`, `private.job_runs` | 90 days | `ops-alerts-cleanup`, `privacy-purge` |
| Reports | `public.reports` | 1 year after they're handled; open ones stay; the reporter's id goes when they delete their account | `privacy-purge` |
| Moderation log, staff notes, photo flags, links between accounts | `private.moderation_log`, `private.staff_notes`, `public.media_flags`, `private.account_links` | 1 year, 3 years about a banned account (the entry behind a hold in force stays with the hold; a flag counts from its review) | `privacy-purge` |
| Team access log | `private.admin_audit` | 1 year, 3 years about a banned account; append-only, the purge is the only deletion | `privacy-purge` |
| Identity fingerprints (HMAC digests of email, phone, Apple or Google ids) | `private.identity_marks`, `private.deleted_identities` | the account's life (marks of a hold or ban), and a kept account's while it is on hold or banned, then 1 year after its deletion, 3 years for a banned account | `privacy-purge` |
| Who was banned (the account id and dates) | `private.banned_accounts` | the account's life, then 3 years after its erasure | `privacy-purge` |
| Help requests and replies | `private.support_requests`, `private.support_messages` | 3 years after the last exchange | `privacy-purge` |
| Purchases | `public.purchase_events`, `private.purchase_credits` | 10 years after the event (accounting); unlinked from the account when it's deleted | `privacy-purge`, `on delete set null` |
| Backups | Supabase | 30 days at most | dashboard setting, see the workspace [TODO.md](../TODO.md) |
| What providers keep (RevenueCat, Twilio, Resend, Rekognition, Stream, Cloudflare) | their systems | their own retention, under the processing agreements | see the workspace [TODO.md](../TODO.md) |

"About a banned account": `private.banned_accounts` has a row for it, written when the account is banned,
removed if the ban is lifted, and kept 3 years after the account is erased, so a record keeps its 3 years
whatever happened to the identity marks. The deletion record of a kept account
(`private.account_deletions.identities`) never holds an identity in clear: which kinds existed and the
sign-ins' providers and dates only (a check holds it to `private.identities_summary`), and `'{}'` with
`identities_purged_at` once the purge cleared it (sophros gets that date as `identitiesPurgedAt` from
`admin_account_deletion`). The digests in `private.deleted_identities` link a later sign-up, and `admin_users`
finds a kept account from its full old email or phone number through them.
`private.admin_audit` stays append-only for everyone: its delete trigger lets a row go only inside a running
purge (recognised by its `private.job_runs` row for the current transaction, which no other role can write) and
only once past its period.

`privacy-purge` and `outbox-cleanup` are watched (`private.watched_jobs`): when one has no completed run in 26
hours, or pg_cron recorded a failed run since the last one, `ops_check` opens an incident and the team's email
lists it under "Daily jobs behind"; the daily summary says what each job deleted. A failed erasure event
(`outbox_policies.erasure`: `media.deleted`, `selfie.delete`, `account.*`, `stream.user`) is never dropped: it
keeps the incident open until someone replays or discards it in sophros.

### Accounts, chats and selfies kept for safety

What is kept for members' safety is erased on the privacy policy's schedule, outside the database too. A daily
job, `private.queue_retention_purges()` (`retention-purge-external`, migration `20260930000201`, watched like
the others), queues one outbox event per thing due, a second apart; db-events erases it, after asking the
database again whether it is still due. The erasure itself is one module, `_shared/erase.ts`, which
`delete-account` uses too.

| Kept | Erased | Event |
| --- | --- | --- |
| An account kept for safety (banned, held or reported when its owner deleted it) | 1 year after its case is closed: any chat of its left (they ended at its deletion, so most went a year after it), its Stream user and messages, R2 `u/<id>/`, its selfies, then its Auth user and its rows (a banned account's moderation history stays, for its 3 years) | `account.purge` |
| The chat of an ended match (frozen by `match.ended`), and a chat kept when an account was deleted because its other member was banned or on hold | 1 year after it ended (the match's end, or the deletion): the chat photos, videos and voice messages its messages point to in R2 (each sender's own objects only, `u/<sender>/chat/…`), then the channel | `chat.erase` |
| A banned account's verification selfies | 6 months after the ban (a lifted hold's still go at once, `selfie.delete`) | `selfie.expired` |

When a kept account's case is closed (`private.retained_case_closed_at`): only once it is banned or its hold is
lifted, and no report about it is still open; then at the latest of its deletion, its last hold change (the ban
decided, or the hold lifted) and its last report handled. A kept banned account is erased a year after that (a
report handled after the ban moves the date); its ban stays remembered (`private.banned_accounts`) and its ban's
identity marks stay, so the same email, phone or sign-in still can't come back. Its moderation log, staff notes,
account links and photo flags outlive it: they have no foreign key any more, and a trigger deletes them with any
other account.

Chats are tracked from their end in `private.chat_retention`, by match id, because a chat kept at a deletion
(decision 5.4) outlives its match row. Channels frozen before that migration whose match row was already gone are
found once in Stream (db-events `chat.sweep`, queued by the migration) and tracked from their last update. An
event on its way, or queued in the last week, is not queued again: a failed one is queued again a week after it
was first queued. Stream counts as done only when it says the thing is gone (HTTP 404 or its code 16), a missing
channel is found with a search that never creates one, and a user deletion (a Stream task) is done only when the
task completes.

### Data export

You › Privacy & data › Export my data calls `request_data_export()`, which queues `export.requested`
(migration `20260930000301`). db-events claims the request (`export_begin`: one build at a time, taken back after
15 minutes). An account without an email address gets nothing built: the team is told and the request closed
(`export_closed`, `closed_reason = 'no_email'`; asking again later works). Otherwise it builds the export
(`_shared/export.ts`): `data.json` with what `export_data(user)` returns (account and sign-ins, the profile row with
lifestyle, settings, language and consent, the consent log, sports, prompts, media list, rounded location, wallet
and credits, likes sent, matches, sessions, blocks, reports made, holds, selfie dates, checks of their own photos,
help requests and replies, purchases, devices, IPs, DeviceCheck record, verification texts, push tokens, earlier
requests), the messages the person sent and the reactions they left (Stream, every match, ended ones too: the
latest reactions Stream returns per message), and their own files under `files/` (R2): photos, videos, posters,
voice intro, and the photos, videos and voice messages they sent in chats. Left out on purpose: reports about the
person (they protect whoever made them), likes received, the team's notes, audit log and safety records (identity
marks, links between accounts), copies of the profile (`profile_cards`). A pgTAP test lists every table naming an
account as exported or left out, so a new one has to choose. A file the database lists but R2 doesn't have is
listed in `data.json` with a note, and logged.

The export comes in parts, zips of at most `EXPORT_MAX_BYTES` bytes each (function secret, 45 MiB by default,
under the 50 MiB a Storage upload takes by default; validated: a bad value fails the export clearly, and so does a
`data.json` too big for one part). Part 1 holds `data.json` and the first files; the next files fill the next
parts, in order; `data.json` lists every file with its part (`files.list`). The parts are built and stored one at
a time: at most one part's files plus its archive in memory, about twice `EXPORT_MAX_BYTES`. Each goes to the
private Storage bucket `data-exports` at `<user id>/<request id>-<part>.zip`, and the parts are recorded at once
(`export_stored`, only the request's own paths), so they expire 7 days on whatever happens next; if the request
went meanwhile (the account erased), db-events deletes them. The person gets one email in their language with one
button (part 1 when there are several) and the other parts as plain links, each valid 7 days (Reply-To
SUPPORT_INBOX); then the request is fulfilled (`export_ready`). A file larger than a part on its own stays out,
listed with a note, and the team gets a short email to send it another way; with the default limit it can't
happen (a file is 40 MiB at most, media-upload-url signs each upload's size).

`data-exports-expire` (hourly) queues `export.expired` 7 days on, which deletes every part. `data-exports-sweep`
(daily) queues `export.sweep` for objects of the bucket no request refers to, a day old at least (a build that
failed for good). Both are erasures: a failed one waits for the team. `delete-account` deletes the account's
folder at once, all parts of all its exports. An account kept for safety keeps its export until it expires.

### Deleting an account without the app

A member can delete their account in the app (`delete-account`), or, without the app (what Google Play asks for),
by writing to support@getdrafft.com, as the website says: from the account's email address, subject "Delete my
account"; without access to it anymore, from another address giving the account's phone number, which the team
asks them to confirm. drafft deletes the account **within 30 days at most** and confirms by email.

- **Who:** an admin (`private.staff` role `admin`), in sophros, on the account's page. Support staff can't: nothing
  undoes a deletion, so it takes an admin, who checks who is asking first.
- **How:** `admin_account_deletion_preview(actor, user, reference?)` → `{status: "deleted"}`, `{status:
  "pending"}`, or `{status: "ready", outcome: "erased" | "kept", basis?, emails, emailed}`: whether the account
  will be erased or kept for members' safety (banned, held or under an open report, with the basis) and where the
  confirmation goes. `admin_delete_account(actor, user, reason, reference)` → `{expected, emails, emailed}` needs a
  reason (`reason_required`) and the request's reference: its support reference `DR-XXXXXX` (`invalid_reference`
  when it isn't one, `unknown_reference` when no request has it) or `email`; `not_found`, `already_deleted`,
  `already_requested` otherwise. It writes `account.delete` to the audit log (reason, reference, expected
  outcome), keeps the addresses and language in `private.staff_deletions` (the account's email, and the
  request's address when it differs; cleared once the confirmation is sent, the row gone after 30 days, never in
  the queue), and queues `account.staff_delete` with the row's id (one at a time per account; migration
  `20260930000601`).
- **What:** db-events runs the very deletion `delete-account` runs (`_shared/erase.ts`, `deleteAccount`): kept
  for safety as a soft delete, or erased with its chats (except those kept for a banned or held member), R2 media,
  selfies, data exports and the Auth user, decided again at that moment. It records the real outcome
  (`staff_deletion_done`, `account.deleted` in the audit log, `erased` or `kept`), then emails each address a
  confirmation in the member's language (`accountDeleted`, Reply-To the support address, `SUPPORT_ADDRESS`, else
  SUPPORT_INBOX), whichever the outcome: for the member, the account is gone either way. No address at all: the
  team gets an email to confirm another way.

## Local development

```sh
cp supabase/.env.example supabase/.env   # Apple and Google values for config.toml, optional
supabase start            # ports 55420-55429, so it runs next to other Supabase projects
supabase test db          # 217 pgTAP tests (supabase/tests/database)
deno run -A scripts/load-areas.ts local   # the areas for area_at; again after a db reset
scripts/local-env.sh      # once: functions/.env.local from .env.staging with local values; yours to edit after
supabase functions serve --env-file supabase/functions/.env.local
# in the app repository: scripts/local-backend.sh (--device for an iPhone on the same Wi-Fi)
```

Without `functions/.env.staging` (fully offline): copy `supabase/functions/.env.example` to
`supabase/functions/.env.local` instead, point `R2_ENDPOINT` at the local Storage S3 API
(`http://host.docker.internal:55421/storage/v1/s3`, `R2_REGION=local`, keys from `supabase status`) and create
a public `drafft-media` bucket.

Update the CLI (`brew upgrade supabase`): the Postgres image bundled with CLI 2.90 (17.6.1.106) crashes when
a role calls a function it has no EXECUTE on from psql. Tests check privileges with `has_function_privilege`
for that reason. Through the API the same call correctly returns 42501.

### Local database, staging services

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

Done once already; kept for the record, not to replay. Production changes only through CI: a `v*` tag runs
`scripts/deploy.sh production` in `.github/workflows/backend.yml` (migrations and functions, after the checks),
which links the CLI back to staging afterwards. Never `supabase link` the production project and `db push`
or `functions deploy` by hand.

1. Supabase project `wrcpgnqwjmnirjfxpcux`, **West EU (Ireland)**; compute Small or larger and PITR before the public launch.
2. Migrations and Edge Functions: a `v*` tag (see Staging). `scripts/deploy.sh production` by hand is a
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
   `media.getdrafft.com`: signed links of about an hour (`?exp=…&sig=…`, optional `&w=` among 160, 320,
   640, 1080), issued by the database (cards, `media_urls`) and the Edge Functions for what the caller may
   see. `MEDIA_SIGNING_KEY` (`openssl rand -hex 32`, one per environment) is the same in the function
   secrets, the Vault (`media_signing_key`, by `scripts/sync-vault.sh`), the Worker and sophros;
   `MEDIA_PUBLIC_URL` is the Worker's domain. The Worker also serves blurred copies at
   `/b/<mode>/<token>?exp=…&sig=…` (the Likes of a free account, `private.blur_url`): the token is the media key
   encrypted then MACed (AES-256-CBC + HMAC-SHA256, keys derived from `MEDIA_SIGNING_KEY`, details in
   `cloudflare/media-worker/src/blur_token.ts`), so the link names neither the person nor the photo; the
   signature binds the mode (`l1`: 200 px, blur 50, WebP) and the expiry, so no change to the link gives the
   original or a sharper copy. It never falls back to the original (no Images binding or a failed
   transformation is a 404); the copy is cached at the edge under an opaque id and never written to R2, so
   deleting a photo or an account leaves nothing behind. Same secret, nothing new to configure.
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
   fails the export), `SUPPORT_INBOUND_SECRET` and `SUPPORT_ADDRESS` (Support by email),
   `TURNSTILE_SECRET_KEY` (the Turnstile widget's secret key: required in both projects, the
   signed-out support form is refused without it and `scripts/ci/env-parity.sh` flags a project missing it).
   Otherwise unset, each feature is skipped and logged. The Vault secret `identity_hash_key` is
   created by migration `20260927000004`: never delete or rotate it, every ban and hold mark would be lost.
   The team acts through sophros (`admin_*` functions, audited in `private.admin_audit`).

## Staging

A persistent Supabase branch named `staging` of `drafft-backend` (its own database, Auth, Storage, Edge
Functions, keys and URL), fed with the same migrations. The app's **Drafft Staging** scheme points at it
(`drafft β` on the home screen, same bundle id as production). Everything goes to staging first: a merge
to `main` deploys it, then a `v*` tag deploys to production (below).

GitHub Actions (`.github/workflows/backend.yml`) does it on its own: every pull request is checked
(Deno type checks, unit tests including the copy against [WORDING.md](WORDING.md), database tests), a push to `main` deploys to staging, and a `v*` tag deploys to
production (the `production` environment only accepts `v*` tags). Migrations and functions only:
secrets are still set by hand, always naming the project: `deploy.sh <env> --secrets` or
`supabase secrets set --project-ref <ref> --env-file supabase/functions/.env.<env>`.

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

Setting it up once:

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

## Not done yet

See the workspace's [TODO.md](../TODO.md) (the parent folder of this checkout): one list for every repository.
