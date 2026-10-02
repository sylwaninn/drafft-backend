# Media

Photos, videos and voice intros live in a private R2 bucket (EU jurisdiction): `drafft-media` in production,
`drafft-media-staging` on staging. Nothing is public: the media Worker (`cloudflare/media-worker`) serves the
bucket on `media.getdrafft.com` (`media-staging.getdrafft.com`) through signed links only.

## Signed links

Links last about an hour (`?exp=…&sig=…`, optional `&w=` among 160, 320, 640, 1080, 1440). They are issued
by the database (cards, `media_urls`) and the Edge Functions, for what the caller may see.

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
nothing behind. Same secret, nothing new to configure.

## Deploy

CI deploys the Worker with each backend deploy, after the functions that delete copies
(`CLOUDFLARE_API_TOKEN` secret, `CLOUDFLARE_ACCOUNT_ID` variable).
