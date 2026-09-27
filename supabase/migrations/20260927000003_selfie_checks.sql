-- The selfie hold (`selfie`, set with set_moderation like the others): the app asks for a selfie with
-- the front camera, checks on the device that a face is in it, and uploads it to a private bucket that
-- only the person can write to, and only while a selfie is asked of them. submit_selfie() then moves
-- the account to `review`: the team compares the selfie with the profile photos and lifts the hold or
-- closes the account.
--
-- Selfies are never shown to other members. They're deleted once the hold is lifted (db-events,
-- `selfie.delete`) or the account is deleted (delete-account); a closed account's are kept, for an appeal.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('verification-selfies', 'verification-selfies', false, 5242880, array['image/jpeg']);

-- Upload only: into the person's own folder, while a selfie is asked of them. No reading, replacing or
-- deleting from the app; the team reads through the service role.
create policy selfie_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'verification-selfies'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and exists (select 1 from public.profiles where id = (select auth.uid()) and moderation = 'selfie')
  );

create table private.selfie_checks (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  path text not null check (char_length(path) <= 200),
  created_at timestamptz not null default now()
);

create index selfie_checks_user_idx on private.selfie_checks (user_id, created_at desc);

-- The app, once the selfie is uploaded: the account goes to review.
create function public.submit_selfie(p_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
begin
  if not exists (select 1 from public.profiles where id = v_me and moderation = 'selfie') then
    perform private.fail('not_requested', 'no selfie was asked for');
  end if;
  if p_path is null or p_path not like v_me::text || '/%' or not exists (
    select 1 from storage.objects where bucket_id = 'verification-selfies' and name = p_path
  ) then
    perform private.fail('invalid_selfie', 'selfie not found');
  end if;
  insert into private.selfie_checks (user_id, path) values (v_me, p_path);
  perform set_config('drafft.moderation_note', 'selfie sent', true);
  update public.profiles set moderation = 'review' where id = v_me;
end;
$$;

grant execute on function public.submit_selfie(text) to authenticated;

-- Lifted: the selfies have done their job.
create function private.on_hold_lifted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.moderation is not null and new.moderation is null
     and exists (select 1 from private.selfie_checks where user_id = new.id) then
    perform private.emit('selfie.delete', jsonb_build_object('userId', new.id));
  end if;
  return null;
end;
$$;

create trigger profiles_hold_lifted after update of moderation on public.profiles
  for each row execute function private.on_hold_lifted();

-- db-events (service role): the selfies to delete, then forget them.
create function public.selfie_paths(p_user uuid)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select path from private.selfie_checks where user_id = p_user;
$$;

create function public.forget_selfies(p_user uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from private.selfie_checks where user_id = p_user;
$$;

revoke execute on function public.selfie_paths(uuid), public.forget_selfies(uuid) from public, anon, authenticated;
grant execute on function public.selfie_paths(uuid), public.forget_selfies(uuid) to service_role;
