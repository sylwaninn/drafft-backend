-- Sessions: the first date is a training session. Proposed with 1 to 3 time options, the other person
-- picks one, declines, or counters with other times (the old proposal becomes `countered`).
-- The chat shows them as custom messages that point to these rows, which stay the source of truth.

create table public.sessions (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches (id) on delete cascade,
  proposer_id uuid not null references public.profiles (id) on delete cascade,
  sport_id text not null references public.sports (id),
  options timestamptz[] not null check (cardinality(options) between 1 and 3),
  chosen_at timestamptz,
  title text not null default '' check (char_length(title) <= 80),
  note text not null default '' check (char_length(note) <= 500),
  tags text[] not null default '{}' check (cardinality(tags) <= 8),
  discovery public.session_discovery,
  status public.session_status not null default 'pending',
  replaces_id uuid references public.sessions (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (status <> 'accepted' or chosen_at is not null),
  check (chosen_at is null or chosen_at = any (options))
);

create index sessions_match_idx on public.sessions (match_id, created_at desc);

create trigger sessions_touch before update on public.sessions
  for each row execute function private.touch_updated_at();

alter table public.sessions enable row level security;

create policy sessions_member_read on public.sessions for select to authenticated
  using (exists (
    select 1 from public.matches m
    where m.id = match_id and (select auth.uid()) in (m.user_a, m.user_b)));

grant select on public.sessions to authenticated;

-- The caller's active match, or an error.
create function private.active_match_for(p_match uuid, p_user uuid)
returns public.matches
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  m public.matches;
begin
  select * into m from public.matches where id = p_match and p_user in (user_a, user_b) and ended_at is null;
  if m.id is null then
    perform private.fail('not_found', 'match not found');
  end if;
  return m;
end;
$$;

create function private.insert_session(
  p_match uuid,
  p_proposer uuid,
  p_proposal jsonb,
  p_replaces uuid default null
)
returns public.sessions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_options timestamptz[];
  v_row public.sessions;
begin
  select array_agg(o::timestamptz order by o::timestamptz) into v_options
  from jsonb_array_elements_text(p_proposal -> 'options') o;
  if v_options is null or exists (select 1 from unnest(v_options) t where t < now()) then
    perform private.fail('invalid_options', 'pick 1 to 3 times in the future');
  end if;
  insert into public.sessions (match_id, proposer_id, sport_id, options, title, note, tags, discovery, replaces_id)
  values (
    p_match, p_proposer, p_proposal ->> 'sport', v_options,
    coalesce(trim(p_proposal ->> 'title'), ''),
    coalesce(trim(p_proposal ->> 'note'), ''),
    coalesce((select array_agg(t) from jsonb_array_elements_text(p_proposal -> 'tags') t), '{}'),
    (p_proposal ->> 'discovery')::public.session_discovery,
    p_replaces)
  returning * into v_row;
  return v_row;
end;
$$;

-- p_proposal: { "sport": "running", "options": ["2026-09-30T07:00:00+02:00", ...], "title": "...",
--               "note": "...", "tags": ["Easy pace"], "discovery": "iTeach" | null }
create function public.propose_session(p_match uuid, p_proposal jsonb)
returns public.sessions
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.active_match_for(p_match, (select auth.uid()));
  return private.insert_session(p_match, (select auth.uid()), p_proposal);
end;
$$;

-- Accept (with one of the options) or decline. Only the person who didn't propose can answer.
create function public.respond_session(p_session uuid, p_accept boolean, p_pick timestamptz default null)
returns public.sessions
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.sessions;
begin
  select * into s from public.sessions where id = p_session for update;
  if s.id is null then
    perform private.fail('not_found', 'session not found');
  end if;
  perform private.active_match_for(s.match_id, (select auth.uid()));
  if s.proposer_id = (select auth.uid()) or s.status <> 'pending' then
    perform private.fail('cannot_respond', 'this session is not waiting for your answer');
  end if;
  if p_accept and (p_pick is null or not p_pick = any (s.options)) then
    perform private.fail('invalid_pick', 'pick one of the proposed times');
  end if;
  update public.sessions
    set status = case when p_accept then 'accepted'::public.session_status else 'declined' end,
        chosen_at = case when p_accept then p_pick end
    where id = p_session
    returning * into s;
  return s;
end;
$$;

-- Answer a pending proposal with other times (and possibly another sport or note).
create function public.counter_session(p_session uuid, p_proposal jsonb)
returns public.sessions
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.sessions;
begin
  select * into s from public.sessions where id = p_session for update;
  if s.id is null then
    perform private.fail('not_found', 'session not found');
  end if;
  perform private.active_match_for(s.match_id, (select auth.uid()));
  if s.proposer_id = (select auth.uid()) or s.status <> 'pending' then
    perform private.fail('cannot_counter', 'this session is not waiting for your answer');
  end if;
  update public.sessions set status = 'countered' where id = p_session;
  return private.insert_session(s.match_id, (select auth.uid()), p_proposal, p_session);
end;
$$;

-- Either person can cancel a pending or accepted session.
create function public.cancel_session(p_session uuid)
returns public.sessions
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.sessions;
begin
  select * into s from public.sessions where id = p_session for update;
  if s.id is null then
    perform private.fail('not_found', 'session not found');
  end if;
  perform private.active_match_for(s.match_id, (select auth.uid()));
  if s.status not in ('pending', 'accepted') then
    perform private.fail('cannot_cancel', 'this session is already closed');
  end if;
  update public.sessions set status = 'cancelled' where id = p_session returning * into s;
  return s;
end;
$$;

-- Sessions tab: pending and accepted sessions that haven't passed, soonest first.
create function public.upcoming_sessions()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(s) || jsonb_build_object(
      'with', jsonb_build_object(
        'id', c.user_id, 'name', c.card ->> 'name', 'photo', c.card -> 'media' -> 0))
  from public.matches m
  join public.sessions s on s.match_id = m.id
  cross join lateral (select case when m.user_a = (select auth.uid()) then m.user_b else m.user_a end as other) o
  join public.profile_cards c on c.user_id = o.other
  where (select auth.uid()) in (m.user_a, m.user_b)
    and m.ended_at is null
    and s.status in ('pending', 'accepted')
    and coalesce(s.chosen_at, s.options[cardinality(s.options)]) > now() - interval '2 hours'
  order by coalesce(s.chosen_at, s.options[1]);
$$;

-- A like can carry a session proposal as its opener: it becomes a real session when the match forms.
create function private.sessions_from_openers()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  sw record;
begin
  for sw in
    select swiper, opener from public.swipes
    where ((swiper = new.user_a and target = new.user_b) or (swiper = new.user_b and target = new.user_a))
      and opener ->> 'kind' = 'session'
  loop
    begin
      perform private.insert_session(new.id, sw.swiper, sw.opener);
    exception when others then
      -- A stale opener (times now in the past) must not block the match itself.
      raise warning 'session opener skipped for match %: %', new.id, sqlerrm;
    end;
  end loop;
  return null;
end;
$$;

create trigger matches_session_openers after insert on public.matches
  for each row execute function private.sessions_from_openers();

grant execute on function
  public.propose_session(uuid, jsonb),
  public.respond_session(uuid, boolean, timestamptz),
  public.counter_session(uuid, jsonb),
  public.cancel_session(uuid),
  public.upcoming_sessions()
  to authenticated;
