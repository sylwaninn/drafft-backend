-- Media keys: the exact shape media-upload-url issues, not just the owner's prefix.
--
-- The three checks only asked for a key starting with `u/<owner>/`. A key built from that prefix could
-- still hold `.` or `..` segments, which URL parsing resolves when an Edge Function reads, moderates or
-- deletes the object, and it had no length limit. Each key now has to be exactly
-- `u/<owner>/<folder>/<name>.<ext>`, with the folder and extensions media-upload-url uses for that field:
--
--   profile_media.key, photo   photos/  jpg, heic, png  (demo/ too: sophros' demo accounts, same shape)
--   profile_media.key, video   videos/  mp4, mov
--   profile_media.poster_key   posters/ jpg, heic, png
--   profiles.voice_intro_key   voice/   m4a, aac
--
-- The name is a UUID from media-upload-url; letters, digits, `-` and `_` (up to 64) keep the fixed names
-- of the tests and the bench valid. No dot is possible outside the extension, so no `.` or `..` segment.
-- Added `not valid` then validated: the check of existing rows runs without blocking writes.

alter table public.profile_media drop constraint media_key_owned;
alter table public.profile_media add constraint media_key_owned check (
  char_length(key) <= 200 and case kind
    when 'photo' then key ~ ('^u/' || user_id::text || '/(photos|demo)/[A-Za-z0-9_-]{1,64}\.(jpg|heic|png)$')
    when 'video' then key ~ ('^u/' || user_id::text || '/videos/[A-Za-z0-9_-]{1,64}\.(mp4|mov)$')
    else false
  end
) not valid;

alter table public.profile_media drop constraint poster_key_owned;
alter table public.profile_media add constraint poster_key_owned check (
  poster_key is null or (
    char_length(poster_key) <= 200
    and poster_key ~ ('^u/' || user_id::text || '/posters/[A-Za-z0-9_-]{1,64}\.(jpg|heic|png)$')
  )
) not valid;

alter table public.profiles drop constraint voice_key_owned;
alter table public.profiles add constraint voice_key_owned check (
  voice_intro_key is null or (
    char_length(voice_intro_key) <= 200
    and voice_intro_key ~ ('^u/' || id::text || '/voice/[A-Za-z0-9_-]{1,64}\.(m4a|aac)$')
  )
) not valid;

alter table public.profile_media validate constraint media_key_owned;
alter table public.profile_media validate constraint poster_key_owned;
alter table public.profiles validate constraint voice_key_owned;
