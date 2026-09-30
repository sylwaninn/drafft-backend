-- The portrait (the first photo people see) must be an approved photo that shows a face, and the server
-- decides it. Until now the face was only checked on the phone and complete_onboarding took a photo of any
-- status, so a sign-up could finish on a photo moderation refused or hadn't judged yet.
--
-- - profile_media.face: Rekognition DetectFaces runs with the moderation check (db-events `media.created`)
--   and records whether a face big enough to recognise is on the photo. null: never checked (photos from
--   before this migration, an image over Rekognition's 5 MB, local development without Rekognition).
-- - The card's portrait: the first approved photo (by position) whose face isn't known to be missing. The
--   other approved media follow in the person's order. With no such photo, photo_count is 0: the profile
--   stays out of Discover (private.eligible) and can't boost, as with no approved photo at all.
-- - complete_onboarding() needs that portrait (`portrait_required`): a pending, refused or faceless photo
--   never opens a profile. Pending and refused photos stay the owner's (to ask for a second look), and were
--   already never on a card.

alter table public.profile_media add column face boolean;
comment on column public.profile_media.face is
  'A recognisable face on the photo (Rekognition DetectFaces, with moderation); null when never checked.';

-- MARK: The verdict, with the face

-- The same verdict as before, plus the face. Replaced rather than overloaded: two versions with defaults
-- would make the three-argument call ambiguous.
drop function public.apply_media_verdict(uuid, text, text[]);
create function public.apply_media_verdict(
  p_media uuid, p_verdict text, p_labels text[] default '{}', p_face boolean default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.profile_media;
begin
  if p_verdict not in ('approved', 'rejected', 'review') then
    perform private.fail('invalid_verdict', 'approved, rejected or review');
  end if;
  select * into m from public.profile_media where id = p_media and status = 'pending' for update;
  if not found then
    return false;
  end if;
  -- 'review' leaves the photo pending for a person; the face is kept either way.
  update public.profile_media
    set status = case when p_verdict = 'review' then status else p_verdict::public.media_status end,
        face = coalesce(p_face, face)
    where id = p_media;
  -- 'review' leaves the photo pending: a retry must not flag it twice.
  if p_verdict <> 'approved' and not exists (
    select from public.media_flags f
    where f.context = 'profile' and f.key = m.key and f.reviewed_at is null
  ) then
    insert into public.media_flags (user_id, context, key, verdict, labels)
      values (m.user_id, 'profile', m.key, p_verdict, coalesce(p_labels, '{}'));
  end if;
  return true;
end;
$$;

revoke execute on function public.apply_media_verdict(uuid, text, text[], boolean) from public, anon, authenticated;
grant execute on function public.apply_media_verdict(uuid, text, text[], boolean) to service_role;

-- MARK: The portrait

-- The photo a card opens on: the first approved photo whose face isn't known to be missing. Null: none.
create function private.portrait(p_user uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.id from public.profile_media m
  where m.user_id = p_user and m.kind = 'photo' and m.status = 'approved' and m.face is not false
  order by m.position
  limit 1;
$$;

revoke execute on function private.portrait(uuid) from public, anon, authenticated;

-- As in 20260925000003, with the portrait first and photo_count at 0 without one.
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
      where m.user_id = p.id and m.status = 'approved'), '[]'::jsonb),
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

-- MARK: Onboarding

-- As in 20260930000001, with the portrait instead of any photo.
create or replace function public.complete_onboarding()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  p public.profiles;
  u record;
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  select * into p from public.profiles where id = v_me for update;
  if p.id is null then
    perform private.fail('not_found', 'profile not found');
  end if;
  if p.onboarded_at is not null then
    return;
  end if;
  select email_confirmed_at, phone, phone_confirmed_at into u from auth.users where id = v_me;
  if u.email_confirmed_at is null then
    perform private.fail('email_unconfirmed', 'confirm your email first');
  end if;
  if u.phone_confirmed_at is null or coalesce(u.phone, '') = '' then
    perform private.fail('phone_required', 'verify your phone number first');
  end if;
  if p.terms_accepted_at is null or p.sensitive_consent_at is null then
    perform private.fail('terms_required', 'accept the terms and the use of your sensitive data first');
  end if;
  if char_length(trim(p.name)) = 0 then
    perform private.fail('name_required', 'name is required');
  end if;
  if p.birthdate is null or p.birthdate > current_date - interval '18 years' then
    perform private.fail('underage', 'you must be 18 or older');
  end if;
  if p.gender is null then
    perform private.fail('gender_required', 'gender is required');
  end if;
  if cardinality(p.sport_ids) = 0 then
    perform private.fail('sport_required', 'add at least one sport');
  end if;
  if not exists (select 1 from public.profile_media m where m.user_id = v_me and m.kind = 'photo') then
    perform private.fail('photo_required', 'add at least one photo');
  end if;
  -- A photo still being checked, refused, or without a face never opens a profile.
  if private.portrait(v_me) is null then
    perform private.fail('portrait_required', 'your first photo must be approved and show your face');
  end if;
  update public.profiles set onboarded_at = now() where id = v_me;
end;
$$;

-- Cards and photo counts follow the new portrait rule now (a first approved video no longer opens a card).
select private.rebuild_card(id) from public.profiles;
