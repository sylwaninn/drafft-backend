-- The app's notification settings (You › Notifications), so server pushes follow them:
-- db-events checks them before pushing likes, matches and sessions, and a change to messages is
-- mirrored to Stream (chat pushes come from Stream). Previews stay on the device: the app's
-- notification service extension hides message text when they're off.

alter table public.profiles
  add column notify_matches boolean not null default true,
  add column notify_likes boolean not null default true,
  add column notify_messages boolean not null default true,
  add column notify_message_previews boolean not null default false;

grant update (notify_matches, notify_likes, notify_messages, notify_message_previews) on public.profiles
  to authenticated;

create function private.on_notify_messages()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.notify_messages is distinct from old.notify_messages then
    perform private.emit('push.preferences', jsonb_build_object('userId', new.id, 'messages', new.notify_messages));
  end if;
  return null;
end;
$$;

create trigger profiles_notify_messages after update of notify_messages on public.profiles
  for each row execute function private.on_notify_messages();
