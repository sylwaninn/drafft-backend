-- The voice intro no longer has a transcript: the feature is gone from the app.
-- The card builder and the card trigger reference the column, so both are redefined first.

create or replace function private.rebuild_card(p_user uuid)
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
$$;

drop trigger profiles_card_update on public.profiles;
create trigger profiles_card_update
  after update of name, gender, pronouns, neighborhood, bio, goal, favorite_spot, intent, drinks, smokes, diet,
    chronotype, icebreaker, voice_intro_key, voice_duration, voice_levels
  on public.profiles
  for each row execute function private.rebuild_card_from_profile();

alter table public.profiles drop column voice_transcript;

-- Existing cards drop their "transcript" key.
select private.rebuild_card(id) from public.profiles;
