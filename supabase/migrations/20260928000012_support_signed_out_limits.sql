-- The signed-out support form (a sign-up or a reset that got stuck) sends an acknowledgement to whatever
-- address is typed. Its limits now stand on their own:
--
-- - signed in: 5 an hour per account, as before (the account's own email, never a typed one);
-- - signed out: 3 an hour and 5 a day per address, whoever sends them (an address can't be flooded with
--   acknowledgements), and 200 an hour for all signed-out requests together, counted on a column of their
--   own (`signed_out`): a deleted account's requests (user_id set null) no longer eat into that cap, and
--   signed-in traffic never does.
--
-- Every refusal keeps the hint `too_many_requests` (the support function answers 429). The acknowledgement
-- no longer quotes the typed topic (db-events, notices.ts).

alter table private.support_requests add column signed_out boolean not null default false;
-- Rows from before: signed out is all that user_id null can tell (a deleted account looks the same).
update private.support_requests set signed_out = true where user_id is null;

create index support_requests_signed_out_idx on private.support_requests (created_at) where signed_out;

create or replace function public.create_support_request(
  p_user uuid, p_email text, p_language text, p_topic text, p_message text, p_context jsonb default '{}'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reference text;
  v_id bigint;
  v_email text := lower(trim(p_email));
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if p_user is not null then
    if (select count(*) from private.support_requests
        where user_id = p_user and created_at > now() - interval '1 hour') >= 5 then
      perform private.fail('too_many_requests', 'too many messages, try again later');
    end if;
  elsif (select count(*) from private.support_requests
         where signed_out and lower(email) = v_email and created_at > now() - interval '1 hour') >= 3
     or (select count(*) from private.support_requests
         where signed_out and lower(email) = v_email and created_at > now() - interval '1 day') >= 5
     or (select count(*) from private.support_requests
         where signed_out and created_at > now() - interval '1 hour') >= 200 then
    perform private.fail('too_many_requests', 'too many messages, try again later');
  end if;
  loop
    v_reference := 'DR-' || (select string_agg(substr(v_alphabet, 1 + (get_byte(b, i) % 32), 1), '')
      from extensions.gen_random_bytes(6) b, generate_series(0, 5) i);
    exit when not exists (select 1 from private.support_requests where reference = v_reference);
  end loop;
  insert into private.support_requests (reference, user_id, email, language, topic, message, context, signed_out)
    values (v_reference, p_user, trim(p_email),
      case when p_language in ('en', 'fr', 'es', 'de', 'it', 'pt', 'nl') then p_language else 'en' end,
      left(trim(p_topic), 80), trim(p_message), coalesce(p_context, '{}'), p_user is null)
    returning id into v_id;
  perform private.emit('support.created', jsonb_build_object('id', v_id));
  return v_reference;
end;
$$;

revoke execute on function public.create_support_request(uuid, text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.create_support_request(uuid, text, text, text, text, jsonb) to service_role;
