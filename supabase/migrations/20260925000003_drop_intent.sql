-- "Looking for" (intent) leaves drafft entirely: the app no longer asks, shows or filters by it.
-- Order matters: the functions that read the column are rewritten first (a SQL function body is only
-- checked when it runs, so dropping the column first would break Discover and card rebuilds later).

-- Discover: no more 'intents' filter (other filters unchanged).
create or replace function private.eligible(p profiles, p_viewer uuid, p_viewer_gender gender, p_viewer_sports text[], p_filters jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
    and (jsonb_array_length(coalesce(p_filters -> 'sports', '[]')) = 0
         or p.sport_ids && array(select jsonb_array_elements_text(p_filters -> 'sports')))
    and (not coalesce((p_filters ->> 'sharedSportsOnly')::boolean, false) or p.sport_ids && p_viewer_sports)
    and not exists (select 1 from public.swipes x where x.swiper = p_viewer and x.target = p.id)
    and not exists (select 1 from public.blocks b where b.blocker = p_viewer and b.blocked = p.id)
    and not exists (select 1 from public.blocks b where b.blocker = p.id and b.blocked = p_viewer)
    and not exists (
      select 1 from public.matches m where m.user_a = least(p_viewer, p.id) and m.user_b = greatest(p_viewer, p.id));
$function$;

-- Cards: the same card, without vitals.intent.
create or replace function private.rebuild_card(p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      'drinks', p.drinks, 'smokes', p.smokes, 'diet', p.diet, 'chronotype', p.chronotype),
    'icebreaker', p.icebreaker,
    'voiceIntro', case when p.voice_intro_key is not null then jsonb_build_object(
      'key', p.voice_intro_key, 'duration', p.voice_duration, 'levels', to_jsonb(p.voice_levels)) end,
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
$function$;

-- The card trigger watches the column: it steps aside and comes back identical, minus intent.
-- profiles_card_update is recreated just below, without intent.
drop trigger profiles_card_update on public.profiles;
-- migration-guard: allow destructive drop - intent (column and type) leaves the product; no client reads or writes it any more
alter table public.profiles drop column intent;
drop type public.intent;
create trigger profiles_card_update after update of name, gender, pronouns, neighborhood, bio, goal,
  favorite_spot, drinks, smokes, diet, chronotype, icebreaker, voice_intro_key, voice_duration,
  voice_levels on public.profiles
  for each row execute function private.rebuild_card_from_profile();

-- Existing cards drop the key too.
select private.rebuild_card(id) from public.profiles;
