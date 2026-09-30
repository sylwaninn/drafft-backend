-- A photo reaches the profile only once its owner saves it. Until now a picked photo was registered at
-- once (add_profile_media) and went on the card as soon as moderation approved it, even when the person
-- then discarded their changes.
--
-- - profile_media.published_at: null while the photo is a draft (picked, uploaded and moderated, so the
--   person sees the verdict before saving), set when a save or the end of sign-up keeps it. The card, the
--   portrait and so Discover only ever use published photos. Existing rows are published.
-- - add_profile_media(p_draft): the app registers drafts. Without it (app versions from before this
--   migration), a photo is published at once, as before.
-- - save_profile_media(p_ids, p_removed): what Save and the end of sign-up send, in one transaction. p_ids is
--   the profile's photos in order, published by the call; p_removed the ones taken off, deleted. Published
--   photos neither kept nor removed (saved from another device meanwhile) stay, after the list; drafts not
--   in the list stay drafts. A live profile never loses its portrait here (`portrait_required`).
-- - delete_media: the same portrait rule, for a photo deleted on its own (a refused one from its sheet, a
--   draft when the person leaves without saving).
-- - Drafts nobody saved (the app was closed before it could delete them) go after 7 days
--   (`media-drafts-purge`); the db-events function deletes their objects.
-- - Locks: every writer takes the owner's media rows first (private.lock_media, in id order), then the
--   profile row through the card trigger, like apply_media_verdict and the staff decisions do: one order, no
--   deadlock. Two saves or deletes at once run one after the other.

-- Published unless registered as a draft: existing rows, and rows written by the server itself.
alter table public.profile_media add column published_at timestamptz default now();
comment on column public.profile_media.published_at is
  'When the owner saved the photo on their profile; null while it is a draft, never on the card.';

-- MARK: Locks

-- Locks the person's media rows, always in the same order.
create function private.lock_media(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1 from public.profile_media where user_id = p_user order by id for update;
end;
$$;

revoke execute on function private.lock_media(uuid) from public, anon, authenticated;

-- MARK: The portrait and the card, from published photos

-- As in 20260930000801, published photos only.
create or replace function private.portrait(p_user uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.id from public.profile_media m
  where m.user_id = p_user and m.kind = 'photo' and m.status = 'approved' and m.face is not false
    and m.published_at is not null
  order by m.position
  limit 1;
$$;

-- As in 20260930000801, published media only.
create or replace function private.rebuild_card(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card jsonb;
  v_portrait uuid := private.portrait(p_user);
begin
  select jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'gender', p.gender,
    'pronouns', p.pronouns,
    'neighborhood', p.neighborhood,
    'bio', p.bio,
    'goal', p.goal,
    'favoriteSpot', p.favorite_spot,
    'vitals', jsonb_build_object(
      'drinks', p.drinks, 'smokes', p.smokes, 'diet', p.diet, 'chronotype', p.chronotype),
    'icebreaker', p.icebreaker,
    'voiceIntro', case when p.voice_intro_key is not null then jsonb_build_object(
      'key', p.voice_intro_key, 'duration', p.voice_duration, 'levels', to_jsonb(p.voice_levels)) end,
    'media', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'kind', m.kind, 'key', m.key, 'width', m.width, 'height', m.height,
        'thumbhash', m.thumbhash, 'duration', m.duration, 'posterKey', m.poster_key)
        order by m.id is not distinct from v_portrait desc, m.position)
      from public.profile_media m
      where m.user_id = p.id and m.status = 'approved' and m.published_at is not null), '[]'::jsonb),
    'sports', coalesce((
      select jsonb_agg(jsonb_build_object('sport', s.sport_id, 'perWeek', s.per_week) order by s.position)
      from public.profile_sports s
      where s.user_id = p.id), '[]'::jsonb),
    'prompts', coalesce((
      select jsonb_agg(jsonb_build_object('question', q.question, 'answer', q.answer) order by q.position)
      from public.profile_prompts q
      where q.user_id = p.id), '[]'::jsonb)
  )
  into v_card
  from public.profiles p
  where p.id = p_user;

  if v_card is null then
    return;
  end if;

  insert into public.profile_cards (user_id, card) values (p_user, v_card)
  on conflict (user_id) do update
    set card = excluded.card, version = public.profile_cards.version + 1, updated_at = now()
    where public.profile_cards.card is distinct from excluded.card;

  -- No portrait, nothing to show in Discover.
  update public.profiles
    set photo_count = case when v_portrait is null then 0 else jsonb_array_length(v_card -> 'media') end
    where id = p_user
      and photo_count <> case when v_portrait is null then 0 else jsonb_array_length(v_card -> 'media') end;
end;
$$;

-- MARK: Registering a draft

-- As in 20260928000041, with p_draft. Replaced rather than overloaded: two versions with defaults would make
-- the older call ambiguous.
drop function public.add_profile_media(text, int, int, text, public.media_kind, real, text);
create function public.add_profile_media(
  p_key text,
  p_width int,
  p_height int,
  p_thumbhash text default null,
  p_kind public.media_kind default 'photo',
  p_duration real default null,
  p_poster_key text default null,
  p_draft boolean default false
)
returns public.profile_media
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_position smallint;
  v_row public.profile_media;
begin
  perform private.require_not_held(v_me);
  perform 1 from public.profiles where id = v_me for update;
  select coalesce(max(position) + 1, 0) into v_position from public.profile_media where user_id = v_me;
  if v_position > 8 then
    perform private.fail('media_limit', 'up to 9 photos and videos');
  end if;
  insert into public.profile_media (
    user_id, kind, key, position, width, height, thumbhash, duration, poster_key, published_at)
  values (v_me, p_kind, p_key, v_position, p_width, p_height, p_thumbhash, p_duration, p_poster_key,
    case when p_draft then null else now() end)
  returning * into v_row;
  return v_row;
end;
$$;

revoke execute on function public.add_profile_media(text, int, int, text, public.media_kind, real, text, boolean)
  from public, anon;
grant execute on function public.add_profile_media(text, int, int, text, public.media_kind, real, text, boolean)
  to authenticated;

-- MARK: Saving

create function public.save_profile_media(p_ids uuid[], p_removed uuid[] default '{}')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_ids uuid[] := coalesce(p_ids, '{}');
  v_removed uuid[] := coalesce(p_removed, '{}');
  v_onboarded boolean;
  v_portrait uuid;
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  perform private.lock_media(v_me);
  if cardinality(v_ids) <> (select count(distinct i) from unnest(v_ids) i) or v_ids && v_removed then
    perform private.fail('invalid_order', 'pass each photo once, kept or removed');
  end if;
  -- A kept photo that isn't there (deleted meanwhile): nothing is saved, the app reads the account again.
  if exists (
    select 1 from unnest(v_ids) i
    where not exists (select 1 from public.profile_media m where m.id = i and m.user_id = v_me)) then
    perform private.fail('not_found', 'a photo is no longer there');
  end if;
  select onboarded_at is not null into v_onboarded from public.profiles where id = v_me;
  v_portrait := private.portrait(v_me);

  -- Removed ones already gone are fine.
  delete from public.profile_media where user_id = v_me and id = any(v_removed);

  -- The saved list first, then published photos the save didn't mention, then drafts.
  with ordered as (
    select m.id, (row_number() over (
      order by case when o.ord is not null then 0 when m.published_at is not null then 1 else 2 end, o.ord, m.position
    ) - 1)::smallint as pos
    from public.profile_media m
    left join unnest(v_ids) with ordinality as o(id, ord) on o.id = m.id
    where m.user_id = v_me
  )
  update public.profile_media m
    set position = ordered.pos,
        published_at = case when m.id = any(v_ids) then coalesce(m.published_at, now()) else m.published_at end
    from ordered
    where m.id = ordered.id
      and (m.position <> ordered.pos or (m.id = any(v_ids) and m.published_at is null));

  if v_onboarded and v_portrait is not null and private.portrait(v_me) is null then
    perform private.fail('portrait_required', 'keep an approved photo of your face first');
  end if;
end;
$$;

revoke execute on function public.save_profile_media(uuid[], uuid[]) from public, anon;
grant execute on function public.save_profile_media(uuid[], uuid[]) to authenticated;

-- MARK: Deleting one photo

-- As in 20260924000002, with the portrait kept and the media rows locked first.
create or replace function public.delete_media(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_onboarded boolean;
  v_portrait uuid;
  v_position smallint;
begin
  perform private.lock_media(v_me);
  select onboarded_at is not null into v_onboarded from public.profiles where id = v_me;
  v_portrait := private.portrait(v_me);
  delete from public.profile_media where id = p_id and user_id = v_me returning position into v_position;
  if v_position is null then
    perform private.fail('not_found', 'media not found');
  end if;
  if v_onboarded and v_portrait = p_id and private.portrait(v_me) is null then
    perform private.fail('portrait_required', 'keep an approved photo of your face first');
  end if;
  update public.profile_media set position = position - 1 where user_id = v_me and position > v_position;
end;
$$;

-- MARK: Drafts nobody saved

-- Positions close up after, so the freed places can be used again (add_profile_media takes the next one).
create function private.purge_media_drafts()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  for v_user in
    select distinct user_id from public.profile_media
    where published_at is null and created_at < now() - interval '7 days'
  loop
    perform private.lock_media(v_user);
    delete from public.profile_media
      where user_id = v_user and published_at is null and created_at < now() - interval '7 days';
    with ordered as (
      select id, (row_number() over (order by position) - 1)::smallint as pos
      from public.profile_media where user_id = v_user
    )
    update public.profile_media m set position = ordered.pos
      from ordered where m.id = ordered.id and m.position <> ordered.pos;
  end loop;
end;
$$;

revoke execute on function private.purge_media_drafts() from public, anon, authenticated;

select cron.schedule('media-drafts-purge', '37 3 * * *', 'select private.purge_media_drafts()');
