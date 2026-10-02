# Media

Profile photos and videos, their posters, voice intros and chat media live in a private R2 bucket (EU
jurisdiction): `drafft-media` in production, `drafft-media-staging` on staging, each person's under `u/<id>/`.
Nothing is public: the media Worker (`cloudflare/media-worker`) serves the bucket on `media.getdrafft.com`
(staging: `media-staging.getdrafft.com`) through signed links only.

## Uploads

1. The app asks `media-upload-url` (signed in) for a ticket: `{ purpose, contentType, byteSize }`. The
   purpose sets the folder, the accepted types and the size cap: `profile_photo` 15 MiB, `profile_video`
   40 MiB, `video_poster` and `voice_intro` 5 MiB, `chat_photo` 15 MiB, `chat_video` 100 MiB, `chat_voice`
   10 MiB, `chat_file` 100 MiB. An account on hold gets no chat upload (`moderated`).
2. The answer is a presigned PUT, valid 10 minutes and bound to that type and size: the app sends the bytes
   straight to R2, nothing goes through the functions.
3. A profile photo or video is registered as a draft (`add_profile_media(…, p_draft => true)`) and checked at
   once (`db-events`, Rekognition), but never shown on a card until it is approved and its owner saves the set
   (`save_profile_media`, Save in Edit profile or the end of sign-up). A draft left unsaved goes after 7 days
   (`media-drafts-purge`). The voice intro isn't moderated and reaches cards as soon as it's set.
4. Chat photos and videos are delivered first, then checked silently (`chat-media`): a flag changes nothing for
   either person, the team sees it in sophros.

## Signed links

A link carries `?exp=…&sig=…` (optional `&w=` among 160, 320, 640, 1080, 1440): `sig` is
base64url(HMAC-SHA256(key + "\n" + exp)). `exp` is at least an hour ahead, rounded up to the next quarter hour,
so a link lives 60 to 75 minutes; the Worker refuses any `exp` more than 2 hours ahead. Links are issued by the
database (cards, `media_urls`), the Edge Functions and sophros, for what the caller may see.

`MEDIA_SIGNING_KEY` (`openssl rand -hex 32`, one per environment) is the same in the function secrets, the
Vault (`media_signing_key`, by `scripts/sync-vault.sh`), the Worker and sophros. `MEDIA_PUBLIC_URL` is the
Worker's domain.

## Smaller copies

A photo's smaller copies (`&w=`, WebP at quality 70) are made once and kept in R2 next to it
(`<key>.w<width>.q70.webp`): made at approval for 320, 1080 and 1440 (db-events, `_shared/renditions.ts`), the
others on first view. They are deleted with the photo (`media.deleted`, chat erasure, the account's prefix),
and never served once their original is gone.

Quality 70: measured on 2026-10-01, quality 85 made a 1440 px copy of a 2048 px JPEG as heavy as the original
(350 to 770 kB); 70 takes about a third off with no visible difference on a phone. The quality is in the
copy's key and CDN key, so changing it never serves an old copy; the keys of earlier qualities stay in
`_shared/renditions.ts` (`LEGACY_KEYS`) so deleting a photo still removes them.

## Blurred copies

The Worker also serves blurred copies at `/b/<mode>/<token>?exp=…&sig=…` (the Likes of a free account,
`private.blur_url`). The token is the media key encrypted then MACed (AES-256-CBC + HMAC-SHA256, keys derived
from `MEDIA_SIGNING_KEY`, details in `cloudflare/media-worker/src/blur_token.ts`), so the link names neither
the person nor the photo. The signature binds the mode (`l1`: 200 px, blur 50, WebP) and the expiry, so no
change to the link gives the original or a sharper copy.

It never falls back to the original (no Images binding or a failed transformation is a 404). The copy is
cached at the edge under an opaque id and never written to R2, so deleting a photo or an account leaves
nothing behind. The blur keys are derived from `MEDIA_SIGNING_KEY`: no extra secret.

## Deploy

CI deploys the Worker on every merge into `staging` and every release, after the Edge Functions: the
functions delete the copies the Worker makes, so they must know a new kind of copy (its key) before the Worker
starts making it (`CLOUDFLARE_API_TOKEN` secret, `CLOUDFLARE_ACCOUNT_ID` variable).
