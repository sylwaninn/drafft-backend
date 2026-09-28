-- Stream sends the message pushes itself, from a template (scripts/stream-push.ts) that reads each
-- recipient's Stream user: their name, app language and whether message previews are on. Those live on
-- the profile, so any change to them is mirrored to Stream (db-events `stream.user`, which reads the
-- current profile, so a late or replayed event still writes the right values).

create function private.on_stream_user_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.name is distinct from old.name
    or new.language is distinct from old.language
    or new.notify_message_previews is distinct from old.notify_message_previews then
    perform private.emit('stream.user', jsonb_build_object('userId', new.id));
  end if;
  return null;
end;
$$;

revoke all on function private.on_stream_user_fields() from public, anon, authenticated;

create trigger profiles_stream_user after update of name, language, notify_message_previews on public.profiles
  for each row execute function private.on_stream_user_fields();

insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers)
values ('stream.user', '24 hours', null, null, '{stream}');
