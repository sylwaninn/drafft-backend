-- sophros decisions made of several changes land whole or not at all: a report closed with a hold, a flag
-- closed with a ban, a photo refused with a hold. A refused hold leaves the report, flag or photo as it
-- was; a decision someone already took applies nothing.
begin;
create extension if not exists pgtap with schema extensions;
select plan(28);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create function pg_temp.hold(p_user uuid) returns text language sql as $$
  select coalesce(moderation::text, 'none') from public.profiles where id = p_user;
$$;

create function pg_temp.report(p_reported uuid) returns uuid language sql as $$
  insert into public.reports (reported, reason) values (p_reported, 'harassment') returning id;
$$;

create function pg_temp.flag(p_user uuid, p_key text, p_context text default 'chat') returns bigint language sql as $$
  insert into public.media_flags (user_id, context, key, verdict, labels)
    values (p_user, p_context, p_key, 'rejected', '{Nudity}') returning id;
$$;

create function pg_temp.photo(p_user uuid, p_status public.media_status) returns uuid language sql as $$
  insert into public.profile_media (user_id, key, position, width, height, status)
    values (p_user, 'u/' || p_user || '/photos/' || gen_random_uuid() || '.jpg', 0, 800, 1000, p_status) returning id;
$$;

create function pg_temp.open_flags(p_user uuid) returns bigint language sql as $$
  select count(*) from public.media_flags where user_id = p_user and reviewed_at is null;
$$;

create temp table people as select pg_temp.person('ana@decide.test') as ana, pg_temp.person('bo@decide.test') as bo,
  pg_temp.person('cy@decide.test') as cy, pg_temp.person('dee@decide.test') as dee, pg_temp.person('eve@decide.test') as eve,
  pg_temp.person('fay@decide.test') as fay;

insert into private.staff (email, role) values ('sup@drafft.test', 'support'), ('mod@drafft.test', 'moderator');

-- Two accounts already banned: a moderator can't turn their ban into a lighter hold.
select public.admin_set_hold('mod@drafft.test', bo, 'banned', 'scam') from people;
select public.admin_set_hold('mod@drafft.test', dee, 'banned', 'scam') from people;

select ok(not has_function_privilege('authenticated', 'public.admin_close_report(text, uuid, text, public.moderation_state, text, text)', 'execute')
    and not has_function_privilege('anon', 'public.admin_decide_flags(text, bigint[], text, public.moderation_state, text, text, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.admin_decide_photo(text, uuid, text, public.moderation_state, text, text, text)', 'execute')
    and has_function_privilege('service_role', 'public.admin_close_report(text, uuid, text, public.moderation_state, text, text)', 'execute')
    and has_function_privilege('service_role', 'public.admin_decide_flags(text, bigint[], text, public.moderation_state, text, text, text)', 'execute')
    and has_function_privilege('service_role', 'public.admin_decide_photo(text, uuid, text, public.moderation_state, text, text, text)', 'execute'),
  'the decisions are for the service role only');

-- MARK: Reports

create temp table reports as select pg_temp.report(ana) as on_ana, pg_temp.report(bo) as on_bo from people;

select throws_ok(format($$select public.admin_close_report('sup@drafft.test', %L, 'warned', 'review')$$, (select on_ana from reports)),
  'P0001', 'not allowed', 'support can''t close a report');
select public.admin_close_report('mod@drafft.test', on_ana, 'insults', 'review') from reports;
select is((select handled_by || ': ' || resolution from public.reports where id = (select on_ana from reports)),
  'mod@drafft.test: insults', 'the report is closed');
select is(pg_temp.hold(ana), 'review', 'and its account held, in the same call') from people;
select is((select string_agg(action, ',' order by id) from private.admin_audit where user_id = (select ana from people)),
  'report.resolve,hold.set', 'both are in the audit log');

select throws_ok(format($$select public.admin_close_report('mod@drafft.test', %L, 'again', 'banned')$$, (select on_ana from reports)),
  'P0001', 'no open report', 'a report already closed can''t be closed again');
select is(pg_temp.hold(ana), 'review', 'and the second decision''s ban isn''t applied') from people;

select throws_ok(format($$select public.admin_close_report('mod@drafft.test', %L, 'looked', 'review')$$, (select on_bo from reports)),
  'P0001', 'not allowed', 'a hold the moderator can''t set fails the whole decision');
select is((select handled_at from public.reports where id = (select on_bo from reports)), null, 'so the report stays open');

select public.admin_close_report('mod@drafft.test', on_bo, 'nothing more to do') from reports;
select is(pg_temp.hold(bo), 'banned', 'without a hold, closing leaves the account as it is') from people;

-- MARK: Flags

create temp table flags as select pg_temp.flag(cy, 'u/x/chat/1.jpg') as on_cy, pg_temp.flag(dee, 'u/x/chat/2.jpg') as on_dee,
  pg_temp.flag(cy, 'u/x/chat/3.jpg') as on_cy_again, pg_temp.flag(ana, 'u/x/chat/4.jpg') as on_ana from people;

select throws_ok(format($$select public.admin_decide_flags('sup@drafft.test', array[%s], 'account banned', 'banned', 'nudity')$$,
    (select on_cy from flags)),
  'P0001', 'not allowed', 'support can''t decide on a flag');
select is(pg_temp.open_flags(cy), 2::bigint, 'the flags stay open') from people;

select public.admin_decide_flags('mod@drafft.test', array[on_cy], 'account banned', 'banned', 'nudity in a chat') from flags;
select is(pg_temp.hold(cy), 'banned', 'the sender is banned') from people;
select is((select reviewed_by from public.media_flags where id = (select on_cy from flags)), 'mod@drafft.test',
  'and the flag closed, in the same call');
select is((select string_agg(action || ': ' || reason, ',' order by id) from private.admin_audit where user_id = (select cy from people)),
  'hold.set: nudity in a chat,flag.resolve: account banned', 'each with its reason in the audit log');

select throws_ok(format($$select public.admin_decide_flags('mod@drafft.test', array[%s], 'account held', 'review', 'x')$$,
    (select on_dee from flags)),
  'P0001', 'not allowed', 'a hold the moderator can''t set fails the decision');
select is(pg_temp.open_flags(dee), 1::bigint, 'so the flag stays open, not closed as decided') from people;

select throws_ok(format($$select public.admin_decide_flags('mod@drafft.test', array[%s], 'selfie asked', 'selfie', 'x')$$,
    (select on_cy from flags)),
  'P0001', 'no open flag', 'a flag already decided on can''t be decided again');

select throws_ok(format($$select public.admin_decide_flags('mod@drafft.test', array[%s, %s], 'held', 'review', 'x')$$,
    (select on_cy_again from flags), (select on_ana from flags)),
  'P0001', 'the flags don''t belong to one account', 'one hold, one account');
select is(pg_temp.open_flags(cy) + pg_temp.open_flags(ana), 2::bigint, 'nothing closed') from people;

select public.admin_decide_flags('mod@drafft.test', array[on_ana], 'nothing wrong') from flags;
select is(pg_temp.open_flags(ana), 0::bigint, 'without a hold, the flag is only closed') from people;

-- MARK: Photos

create temp table photos as select pg_temp.photo(eve, 'pending') as pending, pg_temp.photo(fay, 'rejected') as refused,
  pg_temp.photo(dee, 'rejected') as on_banned from people;
select pg_temp.flag(user_id, key, 'profile') from public.profile_media where id in (select refused from photos union all select on_banned from photos);

select public.admin_decide_photo('mod@drafft.test', pending, 'profile photo refused: Nudity', 'review') from photos;
select is((select status::text from public.profile_media where id = (select pending from photos)), 'rejected',
  'a pending photo is refused');
select is(pg_temp.hold(eve), 'review', 'and its account held, in the same call') from people;

select throws_ok(format($$select public.admin_decide_photo('mod@drafft.test', %L, 'again', 'banned')$$, (select pending from photos)),
  'P0001', 'the photo was already decided on', 'a photo already decided on can''t be decided again');
select is(pg_temp.hold(eve), 'review', 'and the second decision''s ban isn''t applied') from people;

select public.admin_decide_photo('mod@drafft.test', refused, 'refusal confirmed', 'banned', 'explicit photos') from photos;
select is(pg_temp.open_flags(fay) || ' ' || pg_temp.hold(fay), '0 banned',
  'a photo the check refused: its flags closed and its account banned') from people;

select throws_ok(format($$select public.admin_decide_photo('mod@drafft.test', %L, 'refused', 'review')$$, (select on_banned from photos)),
  'P0001', 'not allowed', 'a hold the moderator can''t set fails the decision');
select is(pg_temp.open_flags(dee), 2::bigint, 'so the photo''s flag stays open') from people;

select * from finish();
rollback;
