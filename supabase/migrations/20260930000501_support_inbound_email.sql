-- Support by email: what people write to the support address lands in sophros, in the thread of its request.
--
-- Every email sent to a member about their account has Reply-To the support address (SUPPORT_ADDRESS,
-- support@getdrafft.com), and the support ones (the acknowledgement, the team's replies) their reference in the
-- subject ([DR-XXXXXX]). Cloudflare Email Routing hands that address's mail to an Email Worker
-- (cloudflare/support-mail-worker), which posts the message to the `support-inbound` Edge Function (shared
-- secret), which calls receive_support_email(). `p_verified`: Cloudflare vouched for the envelope sender (SPF
-- passed for its domain, or DKIM passed aligned with it); anyone can put any address in an unverified email.
--
-- - verified, a known reference, written from the request's address (or from the current email of its account):
--   the message joins the request as the member's (direction 'in'), and the request reopens; the team gets a
--   copy (`support.received`, to SUPPORT_INBOX);
-- - verified, anything else: a new request from the sender, linked to the account with that email if there is
--   one, acknowledged like the app's form;
-- - unverified: always a new request, linked to no account, never acknowledged (no mail to an address that may
--   not have written), a reference it mentions kept for the team to look at. Another address never joins
--   someone else's thread.
-- The topic is the email's subject, cleaned (no "Re:", no reference), else "Message by email" in the account's
-- language. Email requests have their own limits (5 an hour per address, 200 an hour in all), apart from the
-- app's signed-out form. Each email is taken once, by its Message-ID (private.support_inbound): the Worker may
-- post it again.
-- A team reply is never left "Sending": db-events records any failure on the message, and a reply the outbox
-- gives up on is marked failed if nothing was recorded (private.support_reply_given_up).

-- migration-guard: allow destructive drop - support_reply, recreated at once with the message's direction

-- Who wrote a message: the team, sent from sophros ('out', emailed by db-events), or the member, received by
-- email ('in', sent_at is when it arrived: nothing to send, so no error and no idempotency key).
alter table private.support_messages
  add column direction text not null default 'out' check (direction in ('out', 'in')),
  add constraint support_messages_received check (direction = 'out'
    or (sent_at is not null and error is null and idempotency_key is null));

create table private.support_inbound (
  message_id text primary key check (char_length(message_id) between 1 and 998),
  -- Set in the same transaction as the row (the insert is what takes the Message-ID): never null once committed.
  request_id bigint references private.support_requests (id) on delete cascade,
  received_at timestamptz not null default now()
);

create index support_inbound_request_idx on private.support_inbound (request_id);
create index support_messages_inbound_idx on private.support_messages (request_id, created_at) where direction = 'in';

-- A request's topic from an email's subject: "Re:", "Fwd:" and their translations, and the reference, taken off;
-- empty, a fallback in the person's language.
create function private.email_topic(p_subject text, p_language text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_topic text := regexp_replace(coalesce(p_subject, ''), '\[?\mDR-[A-Z0-9]{6}\M\]?', '', 'gi');
begin
  loop
    exit when v_topic !~* '^\s*(re|fw|fwd|tr|aw|wg|rv|r|enc|antw|sv|vs)\s*:';
    v_topic := regexp_replace(v_topic, '^\s*(re|fw|fwd|tr|aw|wg|rv|r|enc|antw|sv|vs)\s*:', '', 'i');
  end loop;
  v_topic := left(trim(regexp_replace(v_topic, '\s+', ' ', 'g')), 80);
  if v_topic <> '' then
    return v_topic;
  end if;
  return case p_language
    when 'fr' then 'Message par e-mail'
    when 'es' then 'Mensaje por correo'
    when 'de' then 'Nachricht per E-Mail'
    when 'it' then 'Messaggio via email'
    when 'pt' then 'Mensagem por email'
    when 'nl' then 'Bericht per e-mail'
    else 'Message by email' end;
end;
$$;

-- The support-inbound function (service role). Returns { outcome: appended | created | duplicate, reference,
-- truncated }: `truncated` when the text was longer than a message holds (8000 characters in a thread, 4000
-- for a new request), for the Worker to keep the whole email. Refusals: invalid_email, empty_message,
-- too_many_requests (10 an hour into one request, 5 new requests an hour per address, 200 an hour in all).
create function public.receive_support_email(
  p_from text, p_subject text, p_body text, p_reference text default null, p_message_id text default null,
  p_context jsonb default '{}', p_verified boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from text := lower(trim(coalesce(p_from, '')));
  v_subject text := trim(coalesce(p_subject, ''));
  v_body text := trim(coalesce(p_body, ''));
  v_reference text := upper(trim(coalesce(p_reference, '')));
  v_message_id text := nullif(trim(coalesce(p_message_id, '')), '');
  v_verified boolean := coalesce(p_verified, false);
  v_request private.support_requests;
  v_user uuid;
  v_language text;
  v_message bigint;
  v_taken int;
  v_truncated boolean;
  v_context jsonb;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if v_from !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' or char_length(v_from) > 320 then
    perform private.fail('invalid_email', 'no sender address');
  end if;
  if v_body = '' then
    v_body := left(v_subject, 4000);
  end if;
  if v_body = '' then
    perform private.fail('empty_message', 'nothing written');
  end if;

  -- Once per email: a second post of the same Message-ID changes nothing.
  if v_message_id is not null then
    insert into private.support_inbound (message_id) values (v_message_id) on conflict do nothing;
    get diagnostics v_taken = row_count;
    if v_taken = 0 then
      return jsonb_build_object('outcome', 'duplicate', 'truncated', false, 'reference',
        (select r.reference from private.support_inbound i join private.support_requests r on r.id = i.request_id
          where i.message_id = v_message_id));
    end if;
  end if;

  if v_verified and v_reference ~ '^DR-[A-Z0-9]{6}$' then
    select * into v_request from private.support_requests r
      where r.reference = v_reference
        and (lower(r.email) = v_from
             or r.user_id in (select u.id from auth.users u where lower(u.email) = v_from));
  end if;

  if v_request.id is not null then
    if (select count(*) from private.support_messages
        where request_id = v_request.id and direction = 'in' and created_at > now() - interval '1 hour') >= 10 then
      perform private.fail('too_many_requests', 'too many messages, try again later');
    end if;
    v_truncated := char_length(v_body) > 8000;
    insert into private.support_messages (request_id, author, body, direction, sent_at)
      values (v_request.id, v_from, left(v_body, 8000), 'in', now())
      returning id into v_message;
    update private.support_requests set handled_at = null, handled_by = null where id = v_request.id;
    perform private.emit('support.received', jsonb_build_object('id', v_message));
  else
    if (select count(*) from private.support_requests
        where context ->> 'source' = 'email' and lower(email) = v_from and created_at > now() - interval '1 hour') >= 5
       or (select count(*) from private.support_requests
           where context ->> 'source' = 'email' and created_at > now() - interval '1 hour') >= 200 then
      perform private.fail('too_many_requests', 'too many messages, try again later');
    end if;
    if v_verified then
      select u.id, p.language into v_user, v_language
        from auth.users u join public.profiles p on p.id = u.id
        where lower(u.email) = v_from
        order by u.created_at limit 1;
    end if;
    v_truncated := char_length(v_body) > 4000;
    v_context := coalesce(p_context, '{}') || jsonb_build_object('source', 'email', 'verified', v_verified);
    if v_reference <> '' then
      -- A reference this address may not write into (or none that exists): kept for the team to look at.
      v_context := v_context || jsonb_build_object('referenceMentioned', left(v_reference, 20));
    end if;
    -- Within the 2000 bytes a request's context holds, whatever the Worker sent.
    if octet_length(v_context::text) > 2000 then
      v_context := v_context - 'authentication';
    end if;
    if octet_length(v_context::text) > 2000 then
      v_context := v_context - 'attachments' || jsonb_build_object('attachmentsLeftOut', true);
    end if;
    loop
      v_reference := 'DR-' || (select string_agg(substr(v_alphabet, 1 + (get_byte(b, i) % 32), 1), '')
        from extensions.gen_random_bytes(6) b, generate_series(0, 5) i);
      exit when not exists (select 1 from private.support_requests where reference = v_reference);
    end loop;
    insert into private.support_requests (reference, user_id, email, language, topic, message, context, signed_out)
      values (v_reference, v_user, v_from, coalesce(v_language, 'en'), private.email_topic(v_subject, v_language),
        left(v_body, 4000), v_context, false)
      returning * into v_request;
    perform private.emit('support.created', jsonb_build_object('id', v_request.id));
  end if;

  if v_message_id is not null then
    update private.support_inbound set request_id = v_request.id where message_id = v_message_id;
  end if;
  return jsonb_build_object('outcome', case when v_message is null then 'created' else 'appended' end,
    'reference', v_request.reference, 'truncated', v_truncated);
end;
$$;

revoke execute on function public.receive_support_email(text, text, text, text, text, jsonb, boolean)
  from public, anon, authenticated;
grant execute on function public.receive_support_email(text, text, text, text, text, jsonb, boolean) to service_role;
revoke all on function private.email_topic(text, text) from public, anon, authenticated;

-- 20260927000007, plus who wrote the message: db-events emails only the team's ('out') and copies only the
-- member's ('in').
drop function public.support_reply(bigint);
create function public.support_reply(p_id bigint)
returns table (reference text, email text, language text, topic text, message text, body text, author text,
  sent_at timestamptz, direction text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.reference, r.email, r.language, r.topic, r.message, m.body, m.author, m.sent_at, m.direction
  from private.support_messages m join private.support_requests r on r.id = m.request_id
  where m.id = p_id;
$$;

-- 20260927000007: only a team message is sent.
create or replace function public.support_reply_sent(p_id bigint, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.support_messages
    set sent_at = case when p_error is null then now() end, error = p_error
    where id = p_id and direction = 'out';
$$;

revoke execute on function public.support_reply(bigint), public.support_reply_sent(bigint, text)
  from public, anon, authenticated;
grant execute on function public.support_reply(bigint), public.support_reply_sent(bigint, text) to service_role;

-- A reply the outbox gave up on (out of its retry budget, db-events never answering, or discarded in sophros) is
-- marked failed on its message when db-events could not record why, so sophros never shows it "Sending" forever.
-- An error db-events recorded stays; a replay that sends it clears it (support_reply_sent).
create function private.support_reply_given_up()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if jsonb_typeof(new.payload -> 'id') = 'number' then
    update private.support_messages
      set error = left(coalesce(new.last_error, 'discarded: ' || new.discard_reason, 'not sent'), 500)
      where id = (new.payload ->> 'id')::bigint and direction = 'out' and sent_at is null and error is null;
  end if;
  return null;
end;
$$;

create trigger outbox_support_reply_given_up after update of failed_at, discarded_at on private.outbox
  for each row when (new.event = 'support.reply' and new.delivered_at is null
    and (old.failed_at is null and new.failed_at is not null or old.discarded_at is null and new.discarded_at is not null))
  execute function private.support_reply_given_up();

revoke all on function private.support_reply_given_up() from public, anon, authenticated;

-- The team's copy of a member's email (db-events reads it with support_reply).
insert into private.outbox_policies (event, retry_budget, expires_after, push_ttl, providers)
  values ('support.received', '24 hours', null, null, '{resend}');

-- sophros: each message of a thread says who wrote it ('in': the member, by email; 'out': the team).
create or replace function public.admin_support(
  p_actor text, p_open boolean default true, p_query text default '', p_limit int default 60, p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_query text := nullif(trim(coalesce(p_query, '')), '');
begin
  perform private.require_staff(p_actor, 'support');
  return coalesce((
    select jsonb_agg(to_jsonb(s) - 'user_id' || jsonb_build_object('person', private.admin_person(s.user_id),
        'replies', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'author', m.author, 'body', m.body,
            'createdAt', m.created_at, 'sentAt', m.sent_at, 'error', m.error, 'direction', m.direction)
            order by m.created_at), '[]')
          from private.support_messages m where m.request_id = s.id))
      order by s.created_at desc)
    from (select * from private.support_requests
          where (not p_open or handled_at is null)
            and (v_query is null or reference ilike private.like_pattern(v_query) or email ilike private.like_pattern(v_query)
                 or message ilike private.like_pattern(v_query))
          order by created_at desc limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) s), '[]');
end;
$$;
