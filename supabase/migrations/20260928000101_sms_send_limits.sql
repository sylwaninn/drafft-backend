-- Verification SMS to every country (the prefix list is gone), so every send is counted and capped before
-- it costs anything. The app asks the phone-code Edge Function for a code; it checks the account (email
-- confirmed), reserves a send here, checks the line with Twilio Lookup, then asks Auth for the phone change.
-- Auth's Send SMS hook (auth-sms) only texts a number that has an approved reservation for that account:
-- a phone change asked for any other way gets no SMS.
--
-- Limits (refused with `sms_limit`), counted on every reservation, whether or not Lookup accepts it:
--   per number:  3 an hour, 6 a day
--   per account: 5 an hour, 10 a day
--   per IP:      10 an hour, 30 a day
--   in all:      500 an hour (a circuit breaker against SMS pumping; raise it with the traffic)
-- Rows are kept 30 days, then removed by pg_cron. Deleting an account keeps its rows (user_id set null),
-- so deleting and signing up again doesn't reset the counts of a number or an IP.

create table private.sms_sends (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users (id) on delete set null,
  phone text not null check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  ip inet,
  -- Twilio Lookup accepted the line: the hook may send.
  approved_at timestamptz,
  -- The hook sent the code: a reservation texts once.
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create index sms_sends_phone_idx on private.sms_sends (phone, created_at);
create index sms_sends_user_idx on private.sms_sends (user_id, created_at);
create index sms_sends_ip_idx on private.sms_sends (ip, created_at) where ip is not null;
create index sms_sends_created_idx on private.sms_sends (created_at);

-- A send about to be asked for: counted now, refused past a limit. Returns the reservation's id.
create function public.reserve_sms(p_user uuid, p_phone text, p_ip text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip inet;
  v_id bigint;
begin
  if p_user is null or p_phone is null or p_phone !~ '^\+[1-9][0-9]{6,14}$' then
    perform private.fail('phone_invalid', 'not a phone number');
  end if;
  begin
    v_ip := nullif(trim(p_ip), '')::inet;
  exception when others then
    v_ip := null;
  end;
  -- Two requests at once for the same number or account can't both slip under a limit.
  perform pg_advisory_xact_lock(hashtextextended('sms:' || p_phone, 0));
  perform pg_advisory_xact_lock(hashtextextended('sms:' || p_user::text, 0));

  if (select count(*) from private.sms_sends where phone = p_phone and created_at > now() - interval '1 hour') >= 3
     or (select count(*) from private.sms_sends where phone = p_phone and created_at > now() - interval '1 day') >= 6
     or (select count(*) from private.sms_sends where user_id = p_user and created_at > now() - interval '1 hour') >= 5
     or (select count(*) from private.sms_sends where user_id = p_user and created_at > now() - interval '1 day') >= 10
     or (v_ip is not null and (
           (select count(*) from private.sms_sends where ip = v_ip and created_at > now() - interval '1 hour') >= 10
           or (select count(*) from private.sms_sends where ip = v_ip and created_at > now() - interval '1 day') >= 30))
     or (select count(*) from private.sms_sends where created_at > now() - interval '1 hour') >= 500 then
    perform private.fail('sms_limit', 'too many codes, try again later');
  end if;

  insert into private.sms_sends (user_id, phone, ip) values (p_user, p_phone, v_ip) returning id into v_id;
  return v_id;
end;
$$;

-- Twilio Lookup accepted the line of this reservation.
create function public.approve_sms(p_id bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.sms_sends set approved_at = now() where id = p_id and approved_at is null;
$$;

-- Called by the Send SMS hook: true, once, for an approved reservation of this account and number from
-- the last 10 minutes. False otherwise (the hook refuses to send).
create function public.consume_sms(p_user uuid, p_phone text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  select id into v_id from private.sms_sends
    where user_id = p_user and phone = p_phone and approved_at > now() - interval '10 minutes' and used_at is null
    order by created_at desc
    limit 1
    for update skip locked;
  if v_id is null then
    return false;
  end if;
  update private.sms_sends set used_at = now() where id = v_id;
  return true;
end;
$$;

revoke all on function public.reserve_sms(uuid, text, text), public.approve_sms(bigint),
  public.consume_sms(uuid, text) from public, anon, authenticated;
grant execute on function public.reserve_sms(uuid, text, text), public.approve_sms(bigint),
  public.consume_sms(uuid, text) to service_role;

select cron.schedule('sms-sends-cleanup', '17 3 * * *',
  $$delete from private.sms_sends where created_at < now() - interval '30 days'$$);
