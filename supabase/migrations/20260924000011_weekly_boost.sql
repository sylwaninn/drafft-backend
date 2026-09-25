-- drafft tempo's free boost every week.
--
-- Becoming premium credits the first one straight away and sets `weekly_boost_at`, one week later.
-- A pg_cron job credits each boost that comes due (while still premium), moves the date on by a week
-- and emits `boost.weekly`, which db-events turns into a push ("Your weekly boost is here") in the
-- person's language, unless they turned it off in the app's notification settings.

alter table public.wallets add column weekly_boost_at timestamptz;

create index wallets_weekly_boost_idx on public.wallets (weekly_boost_at) where weekly_boost_at is not null;

-- What pushes need to know about the person. Written by the app (PATCH /profiles), read by db-events.
alter table public.profiles
  add column language text not null default 'en' check (language in ('en', 'fr', 'es', 'de', 'it', 'pt', 'nl')),
  add column notify_weekly_boost boolean not null default true;

grant update (language, notify_weekly_boost) on public.profiles to authenticated;

-- Premium starting (first purchase, or back after it lapsed): the first weekly boost, and the date of
-- the next. Premium ending clears the date. Renewals change neither.
create function private.weekly_boost_on_premium()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_was boolean := coalesce(old.premium_until > now(), false);
  v_is boolean := coalesce(new.premium_until > now(), false);
begin
  if v_is and not v_was then
    new.boosts := new.boosts + 1;
    new.weekly_boost_at := now() + interval '7 days';
  elsif not v_is then
    new.weekly_boost_at := null;
  end if;
  return new;
end;
$$;

create trigger wallets_weekly_boost before update of premium_until on public.wallets
  for each row execute function private.weekly_boost_on_premium();

-- One boost per person whose date has come, then the next date: the first one still ahead, so a
-- missed run never credits a backlog.
create function private.credit_weekly_boosts()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_count int := 0;
begin
  for r in
    update public.wallets
      set boosts = boosts + 1,
          weekly_boost_at = weekly_boost_at
            + (floor(extract(epoch from now() - weekly_boost_at) / 604800) + 1) * interval '7 days'
      where weekly_boost_at <= now() and premium_until > now()
      returning user_id, boosts
  loop
    perform private.broadcast(r.user_id, 'wallet', jsonb_build_object('boosts', r.boosts));
    perform private.emit('boost.weekly', jsonb_build_object('userId', r.user_id));
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

select cron.schedule('weekly-boosts', '*/15 * * * *', 'select private.credit_weekly_boosts()');

-- People already subscribed: their weekly boosts start a week from now.
update public.wallets set weekly_boost_at = now() + interval '7 days'
  where premium_until > now() and weekly_boost_at is null;
