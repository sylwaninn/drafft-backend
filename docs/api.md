# API for the apps

## RPCs

RPCs (`POST /rest/v1/rpc/<name>`, signed-in user). Errors carry a stable code in `hint`. Signed out (`anon`),
a client executes no database function: it reads `sports` and calls the public Edge Functions `app-config` and
`support`. How Discover picks and orders cards, and the rules for likes, super likes, boosts and pause:
[matching.md](matching.md).

| Area | RPCs |
| --- | --- |
| Onboarding / Edit profile | `accept_terms(p_version, p_sensitive_consent)`, `PATCH /rest/v1/profiles` (whitelisted columns), `set_sports`, `set_prompts`, `add_profile_media(…, p_draft)`, `save_profile_media(p_ids, p_removed)`, `reorder_media`, `delete_media`, `set_location`, `area_at(p_lat, p_lng)`, `complete_onboarding` |
| Discover | `discover(p_filters, p_limit)`, `swipe(p_target, p_action, p_opener, p_note)`, `undo_last_swipe`, `start_boost` |
| Likes, matches | `liked_me`, `my_matches`, `get_cards(p_ids, p_known)`, `unmatch` |
| Sessions | `propose_session`, `respond_session`, `counter_session`, `cancel_session`, `upcoming_sessions` |
| Safety | `block_user`, `unblock_user`, `blocked_users`, `report_user`, `report_app_open(p_install, p_device)` (each time the app comes to the front: install id, model, OS version, app version, locale, time zone; the IP and country come from the request) |
| Moderation | `request_media_review(p_media)` (a second look at a refused photo), `submit_selfie(p_path)` (after uploading the selfie to the private Storage bucket `verification-selfies`, in the person's own folder, while a selfie is asked) |
| Your data | `request_data_export()` (one open request at a time; the export is emailed as one or more links, see [privacy.md](privacy.md#data-export)) |
| Push | `register_push_token`, `unregister_push_token`; `PATCH /rest/v1/profiles` with `language` (en, fr, es, de, it, pt, nl) and the settings `notify_matches`, `notify_likes`, `notify_messages` (mirrored to Stream), `notify_message_previews`, `notify_reactions`, `notify_session_evening`, `notify_session_hour_before`, `notify_weekly_boost` (the app reads them back at launch) |

## Profile media

A photo or video picked in sign-up or Edit profile is uploaded ([media.md](media.md#uploads)), then registered as a
draft with `add_profile_media(…, p_draft => true)`: moderated at once, never on a card. Save (Edit profile, or the
end of sign-up) publishes the set with `save_profile_media(p_ids, p_removed)`: only approved media reach the card,
and a live profile must keep an approved photo showing a face, else `portrait_required`. Leaving without saving,
the app deletes its drafts (`delete_media`); the server drops any draft left after 7 days. The voice intro is
set on the profile directly and isn't moderated.

## Area

`area_at(p_lat, p_lng)` answers with the area a blurred position falls in, `{"name", "city"}`
("Paris 11", "Lyon 4", "Annecy"), or the nearest one within 3 km, or null (outside France, or areas not
loaded); the app then falls back to its own resolver. Nothing is stored. The areas (`private.areas`) are every
commune of France, Paris, Lyon and Marseille by arrondissement, from Etalab's boundaries (Licence Ouverte),
loaded by `scripts/load-areas.ts`, which `deploy.sh` runs: it loads only when codes or names differ from the
source. Bump its `YEAR` once a year. Error: `invalid_location`.

## Terms and consent

Gender and the genders someone wants to see can reveal their sexual orientation, lifestyle
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

## Likes

With drafft tempo `liked_me` returns full cards; a free account gets per like only
`{likeId, superLike, likedAt, thumbhash, blurUrl}` (no id, name, age, key or sharp URL, and `get_cards` refuses
its likers). `thumbhash` is the first photo's placeholder; `blurUrl` is a signed link of about an hour to a
blurred copy of that photo (200 px wide, strong blur, WebP without metadata), or null without a photo, when the
caller is on hold, or without the Vault secrets. Show the ThumbHash, then the blurred image once loaded; read
`liked_me` again for fresh links. What the link can and cannot open: [media.md](media.md).

## Realtime

Subscribe to the private broadcast channel `user:<your id>`. Events: `like`, `match`,
`match_ended`, `session`, `media`, `wallet` (any change to your wallet: purchase, refund, weekly boost,
`start_boost`, super like, undo, premium starting or ending, RevenueCat transfer; the payload is the whole balance:
`super_likes`, `boosts`, `boost_ends_at`, `premium_until`, `weekly_boost_at`), `moderation`
(the account's hold changed: `{ state }`, null once lifted), `profile` (columns of the profile row changed:
`{ fields }`, names only, never `id`, `created_at`, `updated_at`, `last_active_at` or `moderation`; read the row
again) and `session_revoked` (sign-in sessions ended, by a sign-out, sophros' "sign out everywhere" or a
deletion: `{ sessions }`, the ids; a device whose own session is listed signs out). Broadcasts are best effort:
the apps also read everything again on foreground and on reconnect.

## Reactions

The app sends the emoji itself as the Stream reaction type (`enforce_unique`: one per person per
message) and never on its own messages. Stream's webhook (`scripts/stream-webhook.ts`) calls `stream-webhook`,
which removes self-reactions and pushes "Maya reacted ❤️ to: “…”" to the author, in their language, unless
Messages or Reactions is off; without previews the message text is left out.

## Weekly boost

drafft tempo's weekly boost: subscribing credits one straight away, then `private.credit_weekly_boosts()`
(pg_cron, every 15 min) adds one each week on `wallets.weekly_boost_at` while premium, and pushes
"Your weekly boost is here" (`kind: weekly_boost`) unless `notify_weekly_boost` is off.

## Edge Functions

Signed in unless noted.

| Function | Use |
| --- | --- |
| `media-upload-url` | a presigned R2 upload URL for a profile photo, video or voice intro, or chat media ([media.md](media.md#uploads)) |
| `chat-media` | silent check of a photo or video sent in a chat (`{ flagged }`, nothing changes for either person) |
| `delete-account` | deletes the account, its chats, media, selfies and data exports, or keeps it for safety (erased later by db-events `account.purge`) |
| `device-check` | the device's token, at each launch and sign-in: Apple DeviceCheck on iPhone, Play Integrity (`platform: "android"`) on Android |
| `phone-code` | texts a code to verify a number: email confirmed, limits per number, account and IP, Twilio Lookup (mobile lines only, fails closed) |
| `purchase-sync` | credits a purchase or restore straight away from RevenueCat (see [Purchases](#purchases)) |
| `support` | public: every "Get help" and "Contact us" form, signed in or not (`{ reference }`, see [Support form](#support-form)) |
| `support-inbound` | not for the app: the support mail Worker posts each email the support address receives (shared secret, see [support.md](support.md#support-by-email)) |
| `app-config` | public: `mediaUrl`, where media keys are served from (links themselves come signed) |
| `stream-token` | a Stream Chat token for the chat (`{ apiKey, userId, token }`, 24 hours); creates the Stream user, banned while the account is on hold |

## Purchases

`POST /functions/v1/purchase-sync` (signed in, body `{ "transaction_id": "<store transaction id>" }`
or empty), right after a purchase or a restore, reads the caller's purchases from RevenueCat's REST API v2 and
answers `{ wallet, transaction }`: `wallet` is the updated balance (`super_likes`, `boosts`, `boost_ends_at`,
`premium_until`, `weekly_boost_at`), so the credit doesn't wait for the webhook; `transaction` is
`{ id, credited }` for the transaction asked about (`null` without one). The app trusts `credited`: true once
that consumable is credited to the caller and not refunded, or that subscription is owned and premium is active.
Consumables are credited once per store transaction (`private.purchase_credits`, shared with
`revenuecat-webhook`, which stays the safety net); `premium_until` is copied from the active `drafft_tempo`
entitlement. Only the project's store environment counts (`purchase_environment`). Errors: 429
`too_many_requests` (1 call per 5 s, 30 per hour and account), 503 `sync_not_configured` (secrets missing),
503 `sync_unavailable` (RevenueCat unreachable; the webhook still credits).

### Restore on another account

RevenueCat `TRANSFER` (restore on another drafft account): `premium_until` moves from the `transferred_from`
accounts to the `transferred_to` ones; consumables already credited stay with the account that bought them.

## Support form

`POST /support { topic, message, language, email?, context?, turnstileToken? }` → `{ reference }`:
signed in, the reply goes to the account's email and no captcha is asked. Signed out, `turnstileToken` (a
Cloudflare Turnstile token for `getdrafft.com`, at most 2048 characters) is checked server side against
Siteverify with the `TURNSTILE_SECRET_KEY` function secret. Error codes: `captcha_required` (400, no token),
`captcha_failed` (403, refused by Cloudflare or issued for another hostname), `captcha_not_configured` (500,
hosted project without the secret: signed-out requests are refused and logged; locally the check is skipped with
a warning), plus `invalid_topic`, `invalid_message`, `invalid_email` (400) and `too_many_requests` (429). What
happens to a request next (replies, the support address): [support.md](support.md).

## Auth emails and SMS

Supabase Auth sends none itself. Its Send Email hook calls `auth-email`, which picks the
person's language (`profiles.language`, set at sign-up from the app's `language` metadata) and sends through
Resend: a 6-digit code to confirm sign-up, a new email or a password change (the app types it in), and a
link to reset a forgotten password.

Verification SMS: same for the phone step (sign-up and You, a phone change): the Send SMS hook calls
`auth-sms`, which texts the code through Twilio in the person's language, only to the countries the app
offers. Both go out for real, on staging too: never trigger them with made-up addresses or numbers.
