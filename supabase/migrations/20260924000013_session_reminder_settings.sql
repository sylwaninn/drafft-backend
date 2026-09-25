-- The last two notification settings, so the whole screen is saved on the profile and comes back on a
-- new device. Session reminders are scheduled on the phone (local notifications): the server only
-- keeps the choice.

alter table public.profiles
  add column notify_session_evening boolean not null default true,
  add column notify_session_hour_before boolean not null default true;

grant update (notify_session_evening, notify_session_hour_before) on public.profiles to authenticated;
