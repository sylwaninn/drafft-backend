-- A profile change reaches every device of its owner live: each update of public.profiles broadcasts
-- `profile` on `user:<id>` with the names of the columns that changed ({"fields": ["language", "paused"]}),
-- never their values. The app re-reads its profile (the latest server write wins) and applies pause,
-- settings, language and card fields; it also re-reads on foreground and on reconnect, so a missed
-- broadcast is caught up.
--
-- Purely internal columns are left out, and an update touching only them sends nothing: `last_active_at`
-- (every app open), `updated_at`, `created_at`, `id`, and `moderation` (it has its own `moderation` event).
-- Any other column, including one added later, is synced by default: a new user-facing field is live
-- without another migration, and the topic is private to the owner.

create function private.broadcast_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb := to_jsonb(old);
  v_fields jsonb;
begin
  select coalesce(jsonb_agg(c.key order by c.key), '[]'::jsonb) into v_fields
  from jsonb_each(to_jsonb(new)) c
  where c.value is distinct from v_old -> c.key
    and c.key <> all (array['id', 'created_at', 'updated_at', 'last_active_at', 'moderation']);
  if jsonb_array_length(v_fields) > 0 then
    perform private.broadcast(new.id, 'profile', jsonb_build_object('fields', v_fields));
  end if;
  return null;
end;
$$;

revoke execute on function private.broadcast_profile() from public, anon, authenticated;

create trigger profiles_broadcast_update after update on public.profiles
  for each row when (old is distinct from new) execute function private.broadcast_profile();
