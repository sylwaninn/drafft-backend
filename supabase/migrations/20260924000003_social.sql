-- Swipes, matches, blocks, reports, and the read RPCs that serve cards (discover, likes, matches).

create table public.swipes (
  swiper uuid not null references public.profiles (id) on delete cascade,
  target uuid not null references public.profiles (id) on delete cascade,
  action public.swipe_action not null,
  -- First message carried into the match: { "kind": "icebreakerReply", "quote": "...", "reply": "..." },
  -- { "kind": "photoReply", "mediaId": "...", "reply": "..." }, { "kind": "text", "text": "..." }
  -- or { "kind": "session", "sport": "...", "options": [...], ... } (becomes a real session on match).
  opener jsonb check (
    opener is null
    or (opener ->> 'kind' in ('text', 'icebreakerReply', 'photoReply', 'session')
        and octet_length(opener::text) <= 2000)
  ),
  -- Super like note, shown on their card in your deck.
  note text check (char_length(note) <= 140),
  created_at timestamptz not null default now(),
  primary key (swiper, target),
  check (swiper <> target),
  check (action <> 'pass' or (opener is null and note is null))
);

-- "Who liked me", and the daily like count.
create index swipes_target_idx on public.swipes (target, created_at desc) where action <> 'pass';
create index swipes_swiper_recent_idx on public.swipes (swiper, created_at desc);

create table public.matches (
  id uuid primary key default gen_random_uuid(),
  -- Ordered pair: one row per couple, whoever liked first.
  user_a uuid not null references public.profiles (id) on delete cascade,
  user_b uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  ended_by uuid references public.profiles (id) on delete set null,
  unique (user_a, user_b),
  check (user_a < user_b)
);

create index matches_user_b_idx on public.matches (user_b);

create table public.blocks (
  blocker uuid not null references public.profiles (id) on delete cascade,
  blocked uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);

create index blocks_blocked_idx on public.blocks (blocked);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter uuid references public.profiles (id) on delete set null,
  reported uuid not null references public.profiles (id) on delete cascade,
  reason public.report_reason not null,
  details text not null default '' check (char_length(details) <= 1000),
  created_at timestamptz not null default now(),
  handled_at timestamptz
);

create index reports_open_idx on public.reports (created_at) where handled_at is null;

alter table public.swipes enable row level security;
alter table public.matches enable row level security;
alter table public.blocks enable row level security;
alter table public.reports enable row level security;

create policy matches_member_read on public.matches for select to authenticated
  using ((select auth.uid()) in (user_a, user_b));
create policy blocks_own_read on public.blocks for select to authenticated
  using (blocker = (select auth.uid()));

grant select on public.matches, public.blocks to authenticated;

-- MARK: Helpers

create function private.blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks
    where (blocker = a and blocked = b) or (blocker = b and blocked = a));
$$;

create function private.age_of(p_birthdate date)
returns int
language sql
stable
set search_path = ''
as $$
  select date_part('year', age(current_date, p_birthdate))::int;
$$;

create function private.is_premium(p_user uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select premium_until > now() from public.wallets where user_id = p_user), false);
$$;

-- MARK: Swipe

create function public.swipe(
  p_target uuid,
  p_action public.swipe_action,
  p_opener jsonb default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_match uuid;
begin
  if v_me is null then
    perform private.fail('unauthenticated', 'sign in first');
  end if;
  if p_target = v_me then
    perform private.fail('invalid_target', 'cannot swipe yourself');
  end if;

  -- Serialize the pair: two people liking each other at the same instant must still match.
  perform pg_advisory_xact_lock(hashtextextended(least(v_me, p_target)::text || greatest(v_me, p_target)::text, 0));

  if not exists (select 1 from public.profiles where id = p_target and onboarded_at is not null)
     or private.blocked_between(v_me, p_target) then
    perform private.fail('not_found', 'profile not available');
  end if;

  if p_action = 'like' and not private.is_premium(v_me)
     and (select count(*) from public.swipes
          where swiper = v_me and action = 'like' and created_at > now() - interval '24 hours') >= 20 then
    perform private.fail('daily_like_limit', 'no likes left today');
  end if;

  if p_action = 'superlike' then
    update public.wallets set super_likes = super_likes - 1 where user_id = v_me and super_likes > 0;
    if not found then
      perform private.fail('no_super_likes', 'no super likes left');
    end if;
  end if;

  insert into public.swipes (swiper, target, action, opener, note)
  values (v_me, p_target, p_action,
          case when p_action <> 'pass' then p_opener end,
          case when p_action = 'superlike' then nullif(trim(p_note), '') end)
  on conflict (swiper, target) do nothing;
  if not found then
    perform private.fail('already_swiped', 'already swiped');
  end if;

  if p_action <> 'pass' and exists (
    select 1 from public.swipes where swiper = p_target and target = v_me and action <> 'pass') then
    insert into public.matches (user_a, user_b)
    values (least(v_me, p_target), greatest(v_me, p_target))
    on conflict (user_a, user_b) do nothing
    returning id into v_match;
  end if;

  return jsonb_build_object('matched', v_match is not null, 'matchId', v_match);
end;
$$;

-- Undo the caller's last swipe, if it didn't make a match. A super like is refunded.
create function public.undo_last_swipe()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  s public.swipes;
begin
  select * into s from public.swipes where swiper = v_me order by created_at desc limit 1;
  if s.target is null
     or s.created_at < now() - interval '10 minutes'
     or exists (select 1 from public.matches where user_a = least(v_me, s.target) and user_b = greatest(v_me, s.target)) then
    perform private.fail('cannot_undo', 'nothing to undo');
  end if;
  delete from public.swipes where swiper = v_me and target = s.target;
  if s.action = 'superlike' then
    update public.wallets set super_likes = super_likes + 1 where user_id = v_me;
  end if;
  return s.target;
end;
$$;

-- MARK: Discover

-- Whether `p` belongs in the viewer's deck: onboarded, visible, active this month, inside the
-- filters, wanting to see the viewer's gender, and not swiped, blocked or matched already.
create function private.eligible(
  p public.profiles,
  p_viewer uuid,
  p_viewer_gender public.gender,
  p_viewer_sports text[],
  p_filters jsonb
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p.id <> p_viewer
    and p.onboarded_at is not null
    and not p.paused
    and p.photo_count > 0
    and p.last_active_at > now() - interval '30 days'
    and p.birthdate > current_date - make_interval(years => coalesce((p_filters ->> 'maxAge')::int, 99) + 1)
    and p.birthdate <= current_date - make_interval(years => coalesce((p_filters ->> 'minAge')::int, 18))
    and (jsonb_array_length(coalesce(p_filters -> 'audience', '[]')) = 0
         or (p_filters -> 'audience') ? p.gender::text)
    and (cardinality(p.interested_in) = 0 or p_viewer_gender = any (p.interested_in))
    and (jsonb_array_length(coalesce(p_filters -> 'intents', '[]')) = 0
         or (p_filters -> 'intents') ? p.intent::text)
    and (jsonb_array_length(coalesce(p_filters -> 'sports', '[]')) = 0
         or p.sport_ids && array(select jsonb_array_elements_text(p_filters -> 'sports')))
    and (not coalesce((p_filters ->> 'sharedSportsOnly')::boolean, false) or p.sport_ids && p_viewer_sports)
    and not exists (select 1 from public.swipes x where x.swiper = p_viewer and x.target = p.id)
    and not exists (select 1 from public.blocks b where b.blocker = p_viewer and b.blocked = p.id)
    and not exists (select 1 from public.blocks b where b.blocker = p.id and b.blocked = p_viewer)
    and not exists (
      select 1 from public.matches m where m.user_a = least(p_viewer, p.id) and m.user_b = greatest(p_viewer, p.id));
$$;

create index wallets_boost_idx on public.wallets (boost_ends_at) where boost_ends_at is not null;

-- One batch of cards for the deck, best first: people who super liked you, then boosted people,
-- then nearest. Filters (all optional): maxDistanceKm (null = any), minAge, maxAge, audience (genders),
-- intents, sports, sharedSportsOnly. Audience defaults to the viewer's own preferences, and preferences
-- are mutual: you only see people who want to see you.
--
-- The nearest people come from a KNN walk of the location index that stops as soon as enough of
-- them pass the filters, so the cost doesn't grow with how many people live nearby.
create function public.discover(p_filters jsonb default '{}', p_limit int default 20)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with me as (
    select p.id, p.gender, p.sport_ids, l.geo, (p_filters ->> 'maxDistanceKm')::float8 * 1000 as max_m,
      -- No audience in the filters: the viewer's own preferences.
      case when jsonb_array_length(coalesce(p_filters -> 'audience', '[]')) = 0
        then coalesce(p_filters, '{}') || jsonb_build_object('audience', to_jsonb(p.interested_in))
        else p_filters end as filters
    from public.profiles p
    left join private.locations l on l.user_id = p.id
    where p.id = (select auth.uid())
  ),
  pool as (
    -- Priority: they super liked you.
    select s.swiper as id, true as super_liked_me, false as boosted, s.note
    from me join public.swipes s on s.target = me.id and s.action = 'superlike'
    union all
    -- Priority: boosted right now.
    select w.user_id, false, true, null
    from public.wallets w
    where w.boost_ends_at > now()
    union all
    -- Everyone else, nearest first.
    select near.user_id, false, false, null
    from me
    cross join lateral (
      select l.user_id
      from private.locations l
      join public.profiles p on p.id = l.user_id
      where (me.max_m is null or extensions.st_dwithin(l.geo, me.geo, me.max_m))
        and private.eligible(p, me.id, me.gender, me.sport_ids, me.filters)
      order by l.geo operator(extensions.<->) me.geo
      limit least(greatest(p_limit, 1), 50)
    ) near
  ),
  ranked as (
    select distinct on (p.id)
      p.id, p.birthdate, pool.super_liked_me, pool.boosted, pool.note,
      extensions.st_distance(l.geo, me.geo) as meters
    from pool
    cross join me
    join public.profiles p on p.id = pool.id
    join private.locations l on l.user_id = p.id
    where (me.max_m is null or extensions.st_dwithin(l.geo, me.geo, me.max_m))
      and private.eligible(p, me.id, me.gender, me.sport_ids, me.filters)
    order by p.id, pool.super_liked_me desc, pool.boosted desc
  )
  select c.card || jsonb_build_object(
      'age', private.age_of(r.birthdate),
      'distanceKm', case when r.meters is not null then greatest(1, round(r.meters / 1000))::int end,
      'superLikedMe', r.super_liked_me,
      'superLikeNote', r.note,
      'cardVersion', c.version)
  from ranked r
  join public.profile_cards c on c.user_id = r.id
  order by r.super_liked_me desc, r.boosted desc, r.meters nulls last
  limit least(greatest(p_limit, 1), 50);
$$;

-- MARK: Likes, matches, cards

-- People who liked you and you haven't answered yet, super likes first.
create function public.liked_me(p_limit int default 50, p_before timestamptz default null)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select c.card || jsonb_build_object(
      'age', private.age_of(p.birthdate),
      'superLikedMe', s.action = 'superlike',
      'superLikeNote', s.note,
      'opener', s.opener,
      'likedAt', s.created_at,
      'cardVersion', c.version)
  from public.swipes s
  join public.profiles p on p.id = s.swiper
  join public.profile_cards c on c.user_id = s.swiper
  where s.target = (select auth.uid())
    and s.action <> 'pass'
    and (p_before is null or s.created_at < p_before)
    and p.onboarded_at is not null
    and not exists (select 1 from public.swipes r where r.swiper = s.target and r.target = s.swiper)
    and not private.blocked_between(s.swiper, s.target)
  order by (s.action = 'superlike') desc, s.created_at desc
  limit least(greatest(p_limit, 1), 100);
$$;

-- Active matches with the other person's card. The match id is also the chat channel id.
create function public.my_matches()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
      'matchId', m.id,
      'matchedAt', m.created_at,
      'profile', c.card || jsonb_build_object('age', private.age_of(p.birthdate), 'cardVersion', c.version))
  from public.matches m
  cross join lateral (select case when m.user_a = (select auth.uid()) then m.user_b else m.user_a end as other) o
  join public.profiles p on p.id = o.other
  join public.profile_cards c on c.user_id = o.other
  where (select auth.uid()) in (m.user_a, m.user_b)
    and m.ended_at is null
  order by m.created_at desc;
$$;

-- Cards by id, for refreshing cached cards. Only people you have a relationship with: matched,
-- liked you, or you swiped. `p_known` maps id -> cached version; unchanged cards are skipped.
create function public.get_cards(p_ids uuid[], p_known jsonb default '{}')
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select c.card || jsonb_build_object('age', private.age_of(p.birthdate), 'cardVersion', c.version)
  from unnest(p_ids[1:100]) as i(id)
  join public.profiles p on p.id = i.id
  join public.profile_cards c on c.user_id = i.id
  where c.version > coalesce((p_known ->> i.id::text)::bigint, 0)
    and not private.blocked_between((select auth.uid()), i.id)
    and (
      exists (select 1 from public.swipes s where s.swiper = (select auth.uid()) and s.target = i.id)
      or exists (select 1 from public.swipes s where s.swiper = i.id and s.target = (select auth.uid()) and s.action <> 'pass')
      or exists (select 1 from public.matches m
                 where m.user_a = least((select auth.uid()), i.id) and m.user_b = greatest((select auth.uid()), i.id)));
$$;

-- MARK: Safety

-- Block: they disappear from your deck, likes and chats, and you from theirs. Ends any match.
create function public.block_user(p_target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
begin
  if p_target = v_me then
    perform private.fail('invalid_target', 'cannot block yourself');
  end if;
  insert into public.blocks (blocker, blocked) values (v_me, p_target) on conflict do nothing;
  update public.matches set ended_at = now(), ended_by = v_me
    where user_a = least(v_me, p_target) and user_b = greatest(v_me, p_target) and ended_at is null;
end;
$$;

-- Unblocking puts them back in Discover; the old chat stays closed.
create function public.unblock_user(p_target uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.blocks where blocker = (select auth.uid()) and blocked = p_target;
  delete from public.swipes where swiper = (select auth.uid()) and target = p_target;
$$;

create function public.blocked_users()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
      'id', b.blocked,
      'name', c.card ->> 'name',
      'photo', c.card -> 'media' -> 0,
      'blockedAt', b.created_at)
  from public.blocks b
  join public.profile_cards c on c.user_id = b.blocked
  where b.blocker = (select auth.uid())
  order by b.created_at desc;
$$;

-- A report always blocks too.
create function public.report_user(p_target uuid, p_reason public.report_reason, p_details text default '')
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.reports (reporter, reported, reason, details)
  values ((select auth.uid()), p_target, p_reason, coalesce(p_details, ''));
  perform public.block_user(p_target);
end;
$$;

create function public.unmatch(p_match uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.matches set ended_at = now(), ended_by = (select auth.uid())
    where id = p_match and (select auth.uid()) in (user_a, user_b) and ended_at is null;
  if not found then
    perform private.fail('not_found', 'match not found');
  end if;
end;
$$;

grant execute on function
  public.swipe(uuid, public.swipe_action, jsonb, text),
  public.undo_last_swipe(),
  public.discover(jsonb, int),
  public.liked_me(int, timestamptz),
  public.my_matches(),
  public.get_cards(uuid[], jsonb),
  public.block_user(uuid),
  public.unblock_user(uuid),
  public.blocked_users(),
  public.report_user(uuid, public.report_reason, text),
  public.unmatch(uuid)
  to authenticated;
