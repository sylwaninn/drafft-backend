-- Support by email: what people write to the support address lands in sophros, in the thread of its request.
--
-- Every support email sent to a member (the acknowledgement, the team's replies) has its reference in the subject
-- ([DR-XXXXXX]) and Reply-To the support address (SUPPORT_ADDRESS, support@getdrafft.com). Cloudflare Email
-- Routing hands that address's mail to an Email Worker (cloudflare/support-mail-worker), which posts the message
-- to the `support-inbound` Edge Function (shared secret), which calls receive_support_email():
--
-- - a known reference, written from the request's address (or from the current email of its account): the
--   message joins the request as the member's (direction 'in'), and the request reopens; the team gets a copy
--   (`support.received`, to SUPPORT_INBOX) until sophros is watched;
-- - no reference, an unknown one, or another address: a new request from the sender (topic 'email'), linked to
--   the account with that email if there is one, with the same limits, acknowledgement and team copy as the
--   app's form (create_support_request). Another address never joins someone else's thread.
--
-- Each email is taken once, by its Message-ID (private.support_inbound): the Worker may post it again.

-- Who wrote a message: the team, sent from sophros ('out', emailed by db-events), or the member, received by
-- email ('in', sent_at is when it arrived: nothing to send).
alter table private.support_messages
  add column direction text not null default 'out' check (direction in ('out', 'in'));

create table private.support_inbound (
  message_id text primary key check (char_length(message_id) between 1 and 998),
  request_id bigint references private.support_requests (id) on delete cascade,
  received_at timestamptz not null default now()
);

create index support_inbound_request_idx on private.support_inbound (request_id);
create index support_messages_inbound_idx on private.support_messages (request_id, created_at) where direction = 'in';

-- The support-inbound function (service role). Returns { outcome: appended | created | duplicate, reference,
-- truncated }: `truncated` when the text was longer than a message holds (8000 characters in a thread, 4000
-- for a new request), for the Worker to keep the whole email. Refusals: invalid_email, empty_message,
-- too_many_requests (10 an hour into one request; a new request has the form's limits).
create function public.receive_support_email(
  p_from text, p_subject text, p_body text, p_reference text default null, p_message_id text default null,
  p_context jsonb default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from text := lower(trim(coalesce(p_from, '')));
  v_subject text := left(trim(coalesce(p_subject, '')), 200);
  v_body text := trim(coalesce(p_body, ''));
  v_reference text := upper(trim(coalesce(p_reference, '')));
  v_message_id text := nullif(trim(coalesce(p_message_id, '')), '');
  v_request private.support_requests;
  v_user uuid;
  v_language text;
  v_message bigint;
  v_taken int;
  v_truncated boolean;
  v_context jsonb;
begin
  if v_from !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' or char_length(v_from) > 320 then
    perform private.fail('invalid_email', 'no sender address');
  end if;
  if v_body = '' then
    v_body := v_subject;
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

  if v_reference ~ '^DR-[A-Z0-9]{6}$' then
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
    select u.id, p.language into v_user, v_language
      from auth.users u join public.profiles p on p.id = u.id
      where lower(u.email) = v_from
      order by u.created_at limit 1;
    v_truncated := char_length(v_body) > 4000;
    v_context := coalesce(p_context, '{}') || jsonb_build_object('source', 'email', 'subject', v_subject);
    if v_reference <> '' then
      -- A reference this address may not write into (or none that exists): kept for the team to look at.
      v_context := v_context || jsonb_build_object('referenceMentioned', left(v_reference, 20));
    end if;
    v_reference := public.create_support_request(v_user, v_from, coalesce(v_language, 'en'), 'email',
      left(v_body, 4000), v_context);
    select * into v_request from private.support_requests where reference = v_reference;
  end if;

  if v_message_id is not null then
    update private.support_inbound set request_id = v_request.id where message_id = v_message_id;
  end if;
  return jsonb_build_object('outcome', case when v_message is null then 'created' else 'appended' end,
    'reference', v_request.reference, 'truncated', v_truncated);
end;
$$;

revoke execute on function public.receive_support_email(text, text, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.receive_support_email(text, text, text, text, text, jsonb) to service_role;

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
