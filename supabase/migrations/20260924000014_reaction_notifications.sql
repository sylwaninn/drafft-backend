-- "Reactions" in the app's notification settings: pushes for an emoji on one of your messages
-- (stream-webhook), under Messages. Previews off leaves the message text out of them.

alter table public.profiles add column notify_reactions boolean not null default true;

grant update (notify_reactions) on public.profiles to authenticated;
