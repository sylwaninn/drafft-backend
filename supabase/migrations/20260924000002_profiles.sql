-- Profiles: normalized tables for writes, one denormalized `profile_cards` row per person for reads.
--
-- A profile is read thousands of times for every edit, so the full card (identity, vitals, icebreaker,
-- voice intro, approved media, sports, prompts) is rebuilt by triggers on write. Reading a profile is
-- then a primary-key lookup, whatever the profile contains.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null default '' check (char_length(name) <= 40),
  -- Never exposed to other people: cards carry the computed age only.
  birthdate date,
  gender public.gender,
  -- Genders this person wants to see. Empty = everyone.
  interested_in public.gender[] not null default '{}',
  pronouns text check (char_length(pronouns) <= 30),
  neighborhood text not null default '' check (char_length(neighborhood) <= 60),
  bio text not null default '' check (char_length(bio) <= 500),
  goal text not null default '' check (char_length(goal) <= 200),
  favorite_spot text not null default '' check (char_length(favorite_spot) <= 80),
  intent public.intent,
  drinks text not null default '' check (char_length(drinks) <= 40),
  smokes text not null default '' check (char_length(smokes) <= 40),
  diet text not null default '' check (char_length(diet) <= 40),
  chronotype text not null default '' check (char_length(chronotype) <= 40),
  -- { "kind": "joke", "setup": "...", "punchline": "..." } and so on, one shape per app `Icebreaker` case.
  icebreaker jsonb check (
    icebreaker is null
    or (icebreaker ->> 'kind' in ('twoTruths', 'joke', 'hotTake', 'thisOrThat', 'guess')
        and octet_length(icebreaker::text) <= 2000)
  ),
  voice_intro_key text,
  voice_transcript text not null default '' check (char_length(voice_transcript) <= 1000),
  voice_duration real check (voice_duration between 0 and 60),
  -- Waveform bars for the player, so it draws before the audio is downloaded.
  voice_levels real[] check (cardinality(voice_levels) <= 200),
  -- Denormalized from profile_sports for the discover filter (GIN index).
  sport_ids text[] not null default '{}',
  -- Approved media on the card, kept by rebuild_card(): discover filters on it without opening cards.
  photo_count smallint not null default 0,
  onboarded_at timestamptz,
  paused boolean not null default false,
  last_active_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint voice_key_owned check (voice_intro_key is null or voice_intro_key like 'u/' || id::text || '/%')
);

create index profiles_sport_ids_idx on public.profiles using gin (sport_ids);
create index profiles_discoverable_idx on public.profiles (birthdate) where onboarded_at is not null and not paused and photo_count > 0;

create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();

-- Location is private: only discover() reads it, and it is snapped to a ~1 km grid on write so
-- rounded distances can't be used to trilaterate someone's home.
create table private.locations (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  geo extensions.geography(point, 4326) not null,
  updated_at timestamptz not null default now()
);

create index locations_geo_idx on private.locations using gist (geo);

create table public.profile_media (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind public.media_kind not null default 'photo',
  -- Object key in the media bucket, always under the owner's prefix: u/<user id>/...
  key text not null unique,
  position smallint not null check (position between 0 and 8),
  width int not null check (width > 0),
  height int not null check (height > 0),
  -- ~25 bytes, base64: the app draws it instantly while the real image loads.
  thumbhash text check (char_length(thumbhash) <= 64),
  duration real check (duration is null or duration between 0 and 30),
  poster_key text,
  status public.media_status not null default 'pending',
  created_at timestamptz not null default now(),
  constraint media_key_owned check (key like 'u/' || user_id::text || '/%'),
  constraint poster_key_owned check (poster_key is null or poster_key like 'u/' || user_id::text || '/%'),
  constraint video_has_poster check (kind <> 'video' or (poster_key is not null and duration is not null)),
  constraint media_position_unique unique (user_id, position) deferrable initially deferred
);

create table public.profile_sports (
  user_id uuid not null references public.profiles (id) on delete cascade,
  sport_id text not null references public.sports (id),
  per_week smallint not null check (per_week between 1 and 7),
  position smallint not null check (position between 0 and 11),
  primary key (user_id, sport_id)
);

create table public.profile_prompts (
  user_id uuid not null references public.profiles (id) on delete cascade,
  position smallint not null check (position between 0 and 2),
  question text not null check (char_length(question) between 1 and 80),
  answer text not null check (char_length(answer) between 1 and 300),
  primary key (user_id, position)
);

create table public.wallets (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  -- Credited by the purchase flow (service role only), spent by swipe() and start_boost().
  super_likes int not null default 0 check (super_likes >= 0),
  boosts int not null default 0 check (boosts >= 0),
  boost_ends_at timestamptz,
  premium_until timestamptz
);

create table public.profile_cards (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  card jsonb not null,
  -- Bumped only when the card content changes: the app keeps cards on disk and refetches by version.
  version bigint not null default 1,
  updated_at timestamptz not null default now()
);

-- New auth user: empty profile + wallet. Onboarding fills the profile, complete_onboarding() opens it.
create function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  insert into public.wallets (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- MARK: Card rebuild

create function private.rebuild_card(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card jsonb;
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
      'intent', p.intent, 'drinks', p.drinks, 'smokes', p.smokes, 'diet', p.diet, 'chronotype', p.chronotype),
    'icebreaker', p.icebreaker,
    'voiceIntro', case when p.voice_intro_key is not null then jsonb_build_object(
      'key', p.voice_intro_key, 'transcript', p.voice_transcript,
      'duration', p.voice_duration, 'levels', to_jsonb(p.voice_levels)) end,
    'media', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'kind', m.kind, 'key', m.key, 'width', m.width, 'height', m.height,
        'thumbhash', m.thumbhash, 'duration', m.duration, 'posterKey', m.poster_key) order by m.position)
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

  update public.profiles set photo_count = jsonb_array_length(v_card -> 'media')
    where id = p_user and photo_count <> jsonb_array_length(v_card -> 'media');
end;
$$;

create function private.rebuild_card_from_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.rebuild_card(new.id);
  return null;
end;
$$;

-- Only columns that appear on the card: activity pings and pausing don't rebuild it.
create trigger profiles_card_insert after insert on public.profiles
  for each row execute function private.rebuild_card_from_profile();
create trigger profiles_card_update
  after update of name, gender, pronouns, neighborhood, bio, goal, favorite_spot, intent, drinks, smokes, diet,
    chronotype, icebreaker, voice_intro_key, voice_transcript, voice_duration, voice_levels
  on public.profiles
  for each row execute function private.rebuild_card_from_profile();

create function private.rebuild_card_from_child()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := coalesce(new.user_id, old.user_id);
begin
  if tg_table_name = 'profile_sports' then
    update public.profiles
      set sport_ids = coalesce((
        select array_agg(s.sport_id order by s.position) from public.profile_sports s where s.user_id = v_user), '{}')
      where id = v_user;
  end if;
  perform private.rebuild_card(v_user);
  return null;
end;
$$;

create trigger profile_media_card after insert or update or delete on public.profile_media
  for each row execute function private.rebuild_card_from_child();
create trigger profile_sports_card after insert or update or delete on public.profile_sports
  for each row execute function private.rebuild_card_from_child();
create trigger profile_prompts_card after insert or update or delete on public.profile_prompts
  for each row execute function private.rebuild_card_from_child();

-- MARK: Own-profile RPCs

-- Birthdate is set once, during onboarding.
create function private.lock_birthdate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.onboarded_at is not null and new.birthdate is distinct from old.birthdate then
    perform private.fail('birthdate_locked', 'birthdate cannot change after onboarding');
  end if;
  return new;
end;
$$;

create trigger profiles_lock_birthdate before update of birthdate on public.profiles
  for each row execute function private.lock_birthdate();

create function public.complete_onboarding()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  p public.profiles;
begin
  select * into p from public.profiles where id = v_me for update;
  if p.id is null then
    perform private.fail('not_found', 'profile not found');
  end if;
  if p.onboarded_at is not null then
    return;
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
  update public.profiles set onboarded_at = now() where id = v_me;
end;
$$;

-- Replace all sports at once: [{ "sport": "running", "perWeek": 3 }, ...], in display order.
create function public.set_sports(p_sports jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
begin
  if jsonb_typeof(p_sports) <> 'array' or jsonb_array_length(p_sports) = 0 or jsonb_array_length(p_sports) > 12 then
    perform private.fail('invalid_sports', 'between 1 and 12 sports');
  end if;
  delete from public.profile_sports where user_id = v_me;
  insert into public.profile_sports (user_id, sport_id, per_week, position)
  select v_me, e.value ->> 'sport', (e.value ->> 'perWeek')::smallint, (e.ordinality - 1)::smallint
  from jsonb_array_elements(p_sports) with ordinality as e;
end;
$$;

-- Replace all prompts at once: [{ "question": "...", "answer": "..." }, ...], up to three.
create function public.set_prompts(p_prompts jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
begin
  if jsonb_typeof(p_prompts) <> 'array' or jsonb_array_length(p_prompts) > 3 then
    perform private.fail('invalid_prompts', 'up to 3 prompts');
  end if;
  delete from public.profile_prompts where user_id = v_me;
  insert into public.profile_prompts (user_id, position, question, answer)
  select v_me, (e.ordinality - 1)::smallint, trim(e.value ->> 'question'), trim(e.value ->> 'answer')
  from jsonb_array_elements(p_prompts) with ordinality as e;
end;
$$;

-- Register an uploaded object (see the media-upload-url function). It stays `pending`, invisible to
-- others, until moderation approves it.
create function public.add_profile_media(
  p_key text,
  p_width int,
  p_height int,
  p_thumbhash text default null,
  p_kind public.media_kind default 'photo',
  p_duration real default null,
  p_poster_key text default null
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
  perform 1 from public.profiles where id = v_me for update;
  select coalesce(max(position) + 1, 0) into v_position from public.profile_media where user_id = v_me;
  if v_position > 8 then
    perform private.fail('media_limit', 'up to 9 photos and videos');
  end if;
  insert into public.profile_media (user_id, kind, key, position, width, height, thumbhash, duration, poster_key)
  values (v_me, p_kind, p_key, v_position, p_width, p_height, p_thumbhash, p_duration, p_poster_key)
  returning * into v_row;
  return v_row;
end;
$$;

-- New order for all of the caller's media, as a full list of ids.
create function public.reorder_media(p_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
begin
  if (select count(*) from public.profile_media where user_id = v_me) <> cardinality(p_ids)
     or exists (
       select 1 from unnest(p_ids) as i(id)
       where not exists (select 1 from public.profile_media m where m.id = i.id and m.user_id = v_me)) then
    perform private.fail('invalid_order', 'pass every media id exactly once');
  end if;
  update public.profile_media m
    set position = (o.ordinality - 1)::smallint
    from unnest(p_ids) with ordinality as o(id, ordinality)
    where m.id = o.id and m.user_id = v_me;
end;
$$;

-- Deletes the row and closes the gap. The object itself is removed by the db-events function.
create function public.delete_media(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_position smallint;
begin
  delete from public.profile_media where id = p_id and user_id = v_me returning position into v_position;
  if v_position is null then
    perform private.fail('not_found', 'media not found');
  end if;
  update public.profile_media set position = position - 1 where user_id = v_me and position > v_position;
end;
$$;

-- Coordinates are snapped to 0.01° (~1 km) before storage.
create function public.set_location(p_lat double precision, p_lng double precision)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    perform private.fail('invalid_location', 'coordinates out of range');
  end if;
  insert into private.locations (user_id, geo, updated_at)
  values (
    (select auth.uid()),
    extensions.st_setsrid(extensions.st_makepoint(round(p_lng::numeric, 2)::float8, round(p_lat::numeric, 2)::float8), 4326)::extensions.geography,
    now())
  on conflict (user_id) do update set geo = excluded.geo, updated_at = excluded.updated_at;
  update public.profiles set last_active_at = now() where id = (select auth.uid());
end;
$$;

create function public.start_boost()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ends timestamptz;
begin
  update public.wallets
    set boosts = boosts - 1, boost_ends_at = now() + interval '30 minutes'
    where user_id = (select auth.uid()) and boosts > 0 and coalesce(boost_ends_at, '-infinity') <= now()
    returning boost_ends_at into v_ends;
  if v_ends is null then
    perform private.fail('no_boost', 'no boost left, or one is already running');
  end if;
  return v_ends;
end;
$$;

-- MARK: RLS and grants

alter table public.profiles enable row level security;
alter table public.profile_media enable row level security;
alter table public.profile_sports enable row level security;
alter table public.profile_prompts enable row level security;
alter table public.wallets enable row level security;
alter table public.profile_cards enable row level security;

-- Own rows only. Other people are read through cards returned by RPCs.
create policy profiles_own_read on public.profiles for select to authenticated
  using (id = (select auth.uid()));
create policy profiles_own_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy media_own_read on public.profile_media for select to authenticated
  using (user_id = (select auth.uid()));
create policy sports_own_read on public.profile_sports for select to authenticated
  using (user_id = (select auth.uid()));
create policy prompts_own_read on public.profile_prompts for select to authenticated
  using (user_id = (select auth.uid()));
create policy wallets_own_read on public.wallets for select to authenticated
  using (user_id = (select auth.uid()));
create policy cards_own_read on public.profile_cards for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.profiles, public.profile_media, public.profile_sports, public.profile_prompts,
  public.wallets, public.profile_cards to authenticated;
-- Column-level: onboarding and Edit profile write these directly (PATCH /profiles).
-- sport_ids, onboarded_at, last_active_at and timestamps are server-managed.
grant update (name, birthdate, gender, interested_in, pronouns, neighborhood, bio, goal, favorite_spot, intent,
  drinks, smokes, diet, chronotype, icebreaker, voice_intro_key, voice_transcript, voice_duration, voice_levels,
  paused) on public.profiles to authenticated;

grant execute on function public.complete_onboarding(), public.set_sports(jsonb), public.set_prompts(jsonb),
  public.add_profile_media(text, int, int, text, public.media_kind, real, text), public.reorder_media(uuid[]),
  public.delete_media(uuid), public.set_location(double precision, double precision), public.start_boost()
  to authenticated;
