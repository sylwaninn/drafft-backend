-- What the team needs to investigate an account (sophros, the moderation dashboard): which iPhones it
-- uses, from where, and when it was last opened.
--
-- The app calls report_app_open() each time it comes to the front, signed in: its install id
-- (identifierForVendor), the model, iOS, app version and build, locale and time zone. The database adds
-- the caller's IP and country from the request headers. Two tables:
--
-- - private.devices: one row per account and install, with the last IP and when it was last opened.
-- - private.ips: every IP an account opened the app from, first and last seen.
--
-- Both serve safety only (ban evasion, shared devices, fake accounts), never ranking or ads. Kept 180 days
-- after the last open (IPs) or a year (devices), then pruned; deleted with the account.

create table private.devices (
  user_id uuid not null references public.profiles (id) on delete cascade,
  install_id uuid not null,
  model text not null default '' check (char_length(model) <= 64),
  os_version text not null default '' check (char_length(os_version) <= 32),
  app_version text not null default '' check (char_length(app_version) <= 32),
  app_build text not null default '' check (char_length(app_build) <= 32),
  locale text not null default '' check (char_length(locale) <= 32),
  timezone text not null default '' check (char_length(timezone) <= 64),
  ip inet,
  country text check (char_length(country) = 2),
  opens int not null default 1,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (user_id, install_id)
);

-- Other accounts on the same install, or the same IP.
create index devices_install_idx on private.devices (install_id);
create index devices_last_seen_idx on private.devices (last_seen_at desc);

create table private.ips (
  user_id uuid not null references public.profiles (id) on delete cascade,
  ip inet not null,
  country text check (char_length(country) = 2),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (user_id, ip)
);

create index ips_ip_idx on private.ips (ip, last_seen_at desc);

-- The caller's address, as the API gateway saw it. Null when it can't be told (psql, tests).
create function private.request_ip()
returns inet
language plpgsql
stable
set search_path = ''
as $$
declare
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}');
  v_ip text := coalesce(
    v_headers ->> 'cf-connecting-ip',
    v_headers ->> 'x-real-ip',
    nullif(trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1)), ''));
begin
  return v_ip::inet;
exception when others then
  return null;
end;
$$;

create function private.request_country()
returns text
language sql
stable
set search_path = ''
as $$
  select case when c ~ '^[A-Z]{2}$' and c <> 'XX' then c end
  from upper(coalesce(nullif(current_setting('request.headers', true), '')::jsonb ->> 'cf-ipcountry', '')) c;
$$;

-- The app, when it comes to the front. At most one write a minute per install.
create function public.report_app_open(p_install uuid, p_device jsonb default '{}')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_ip inet := private.request_ip();
  v_country text := private.request_country();
  v_device jsonb := coalesce(p_device, '{}');
begin
  if v_me is null or p_install is null then
    return;
  end if;
  insert into private.devices as d (user_id, install_id, model, os_version, app_version, app_build, locale, timezone, ip, country)
    values (v_me, p_install,
      left(coalesce(v_device ->> 'model', ''), 64), left(coalesce(v_device ->> 'os', ''), 32),
      left(coalesce(v_device ->> 'app', ''), 32), left(coalesce(v_device ->> 'build', ''), 32),
      left(coalesce(v_device ->> 'locale', ''), 32), left(coalesce(v_device ->> 'timezone', ''), 64),
      v_ip, v_country)
    on conflict (user_id, install_id) do update
      set model = excluded.model, os_version = excluded.os_version, app_version = excluded.app_version,
          app_build = excluded.app_build, locale = excluded.locale, timezone = excluded.timezone,
          ip = coalesce(excluded.ip, d.ip), country = coalesce(excluded.country, d.country),
          opens = d.opens + 1, last_seen_at = now()
      where d.last_seen_at < now() - interval '1 minute';
  if v_ip is not null then
    insert into private.ips as i (user_id, ip, country) values (v_me, v_ip, v_country)
      on conflict (user_id, ip) do update
        set last_seen_at = now(), country = coalesce(excluded.country, i.country)
        where i.last_seen_at < now() - interval '1 minute';
  end if;
end;
$$;

grant execute on function public.report_app_open(uuid, jsonb) to authenticated;

select cron.schedule('device-reports-prune', '41 3 * * *', $$
  delete from private.ips where last_seen_at < now() - interval '180 days';
  delete from private.devices where last_seen_at < now() - interval '365 days';
$$);
