# Privacy and data retention

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
| Sign-in events with IP addresses | `auth.audit_log_entries` | not enforced yet | |
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
| Backups | Supabase | 30 days at most | dashboard setting |
| What providers keep (RevenueCat, Twilio, Resend, Rekognition, Stream, Cloudflare) | their systems | their own retention, under the processing agreements | |

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

## Accounts, chats and selfies kept for safety

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

## Data export

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

## Deleting an account without the app

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
