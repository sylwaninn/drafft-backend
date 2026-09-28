-- sophros' audit log, completed (20260928000003): no TRUNCATE, list reads logged, and chat photo flags and
-- matches in an account for moderators and admins only.
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  return v_id;
end $$;

create temp table ids as select pg_temp.person('lea@audit.test') as lea, pg_temp.person('omar@audit.test') as omar;
insert into private.staff (email, role) values ('sup@drafft.test', 'support'), ('mod@drafft.test', 'moderator');
insert into public.matches (user_a, user_b) select least(lea, omar), greatest(lea, omar) from ids;
insert into public.media_flags (user_id, context, key, verdict, labels)
  select lea, 'chat', 'u/' || lea || '/chat/c1.jpg', 'rejected', '{Nudity}'::text[] from ids
  union all
  select lea, 'profile', 'u/' || lea || '/photos/p1.jpg', 'review', '{Suggestive}'::text[] from ids;

create function pg_temp.last_audit() returns private.admin_audit language sql as $$
  select * from private.admin_audit order by id desc limit 1;
$$;

-- MARK: Append-only, TRUNCATE included

select throws_ok('truncate private.admin_audit', 'P0001', 'the audit log is append-only', 'the log can''t be truncated');

-- MARK: List reads are logged

select public.admin_users('sup@drafft.test', 'lea@audit');
select is((pg_temp.last_audit()).action, 'user.search', 'a search is logged');
select is((pg_temp.last_audit()).actor || ' ' || ((pg_temp.last_audit()).details ->> 'query') || ' '
    || ((pg_temp.last_audit()).details ->> 'results'), 'sup@drafft.test lea@audit 1', 'with who, what and how many');
select public.admin_users('sup@drafft.test');
select is((pg_temp.last_audit()).action, 'user.search', 'browsing the list is logged too');

select public.admin_related('sup@drafft.test', (select lea from ids));
select is((pg_temp.last_audit()).action || ' ' || (pg_temp.last_audit()).user_id, 'user.related ' || (select lea from ids),
  'related accounts are logged, with the account');

select public.admin_data_requests('sup@drafft.test');
select is((pg_temp.last_audit()).action, 'data_requests.view', 'data requests are logged');

select throws_ok($$select public.admin_users('someone@else.dev')$$, 'P0001', 'not allowed', 'strangers still read nothing');

-- MARK: One account: support sees counts, moderators the details

create temp table before as select max(id) as id from private.admin_audit;
create temp table sup_view as select public.admin_user('sup@drafft.test', (select lea from ids)) as v;
select is((select count(*) from private.admin_audit where id > (select id from before)), 1::bigint,
  'opening an account still writes one row');
select is((pg_temp.last_audit()).action, 'user.view', 'the user.view row');
select ok(not ((select v from sup_view) ? 'matches'), 'support gets no list of matches');
select is((select jsonb_array_length(v -> 'flags') from sup_view), 1, 'support sees profile flags only');
select is((select v -> 'hidden' from sup_view), '{"chatFlags": 1, "matches": 1}'::jsonb, 'and counts of what is hidden');
select is((select jsonb_array_length(v -> 'related') from sup_view), 0, 'related accounts are still included');

create temp table mod_view as select public.admin_user('mod@drafft.test', (select lea from ids)) as v;
select is((select jsonb_array_length(v -> 'matches') from mod_view), 1, 'a moderator sees the matches');
select ok((select jsonb_array_length(v -> 'flags') = 2 and not v ? 'hidden' from mod_view),
  'and every flag, chat included');

select * from finish();
rollback;
