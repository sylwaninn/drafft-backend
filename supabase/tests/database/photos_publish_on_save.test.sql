-- A photo reaches the profile only once its owner saves it (20260930000901): drafts are moderated but never on
-- the card nor the portrait; save_profile_media publishes, orders and removes in one go; a live profile never
-- loses its portrait (save or delete); drafts nobody saved go after 7 days.
begin;
create extension if not exists pgtap with schema extensions;
select plan(33);

-- Everything onboarding asks for, photos aside.
create function pg_temp.person(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id, email_confirmed_at, phone, phone_confirmed_at)
  values (v_id, p_email, 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000', now(),
    '336' || lpad((floor(random() * 1e8))::bigint::text, 8, '0'), now());
  update public.profiles set name = split_part(p_email, '@', 1), birthdate = '1995-05-05', gender = 'woman',
      terms_version = '2026-09-30', terms_accepted_at = now(), sensitive_consent_at = now()
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position) values (v_id, 'running', 3, 0);
  return v_id;
end $$;

create function pg_temp.as_user(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end $$;

-- The error code a call as that person fails with (private.fail puts it in the hint), or null.
create function pg_temp.hint(p_user uuid, p_sql text) returns text language plpgsql as $$
declare
  v_hint text;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
  end;
  reset role;
  return v_hint;
end $$;

-- Registers a photo as the app does, then gives it a verdict (and a face) as moderation would.
create function pg_temp.pick(p_user uuid, p_name text, p_status text, p_face boolean default true,
  p_draft boolean default true) returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  select id into v_id from public.add_profile_media(
    'u/' || p_user || '/photos/' || p_name || '.jpg', 100, 100, p_draft => p_draft);
  reset role;
  update public.profile_media set status = p_status::public.media_status, face = p_face where id = v_id;
  return v_id;
end $$;

create function pg_temp.save(p_user uuid, p_ids uuid[], p_removed uuid[] default '{}') returns text
language sql as $$
  select pg_temp.hint(p_user, format('select public.save_profile_media(%L::uuid[], %L::uuid[])', p_ids, p_removed));
$$;

create function pg_temp.del(p_user uuid, p_id uuid) returns text language sql as $$
  select pg_temp.hint(p_user, format('select public.delete_media(%L::uuid)', p_id));
$$;

create function pg_temp.card(p_user uuid) returns text[] language sql as $$
  select array(select split_part(m ->> 'key', '/', 4) from public.profile_cards c,
    jsonb_array_elements(c.card -> 'media') m where c.user_id = p_user);
$$;

-- Every row, in position order: name (d: draft).
create function pg_temp.rows(p_user uuid) returns text[] language sql as $$
  select array(select split_part(split_part(key, '/', 4), '.', 1) || case when published_at is null then '(d)' else '' end
    from public.profile_media where user_id = p_user order by position);
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select pg_temp.person('ana@test.dev') as ana, pg_temp.person('ben@test.dev') as ben,
  pg_temp.person('cleo@test.dev') as cleo;
create temp table p (name text primary key, id uuid);
grant select on p, ids to authenticated;

-- MARK: Sign-up

insert into p values ('a1', pg_temp.pick((select ana from ids), 'a1', 'approved'));
select is(pg_temp.rows((select ana from ids)), array['a1(d)'], 'a picked photo is a draft');
select is(pg_temp.card((select ana from ids)), '{}'::text[], 'an approved draft is not on the card');
select is(pg_temp.hint((select ana from ids), 'select public.complete_onboarding()'), 'portrait_required',
  'an approved draft is not a portrait: the sign-up does not finish');
select is(pg_temp.save((select ana from ids), array[(select id from p where name = 'a1')]), null,
  'the end of sign-up saves the photos');
select is(pg_temp.rows((select ana from ids)), array['a1'], 'the saved photo is published');
select is(pg_temp.hint((select ana from ids), 'select public.complete_onboarding()'), null, 'then the sign-up finishes');
select is(pg_temp.card((select ana from ids)), array['a1.jpg'], 'and the photo is on the card');

-- MARK: Edit profile

insert into p values ('a2', pg_temp.pick((select ana from ids), 'a2', 'rejected'));
insert into p values ('a3', pg_temp.pick((select ana from ids), 'a3', 'approved'));
select is(pg_temp.card((select ana from ids)), array['a1.jpg'], 'photos picked in Edit profile stay off the card');

-- The original bug: take the portrait off, keep only the refused photo.
select is(pg_temp.save((select ana from ids), array[(select id from p where name = 'a2')],
  array[(select id from p where name = 'a1')]), 'portrait_required', 'a save that leaves no portrait is refused');
select is(pg_temp.rows((select ana from ids)), array['a1', 'a2(d)', 'a3(d)'], 'and nothing changed');

select is(pg_temp.save((select ana from ids), array[(select id from p where name = 'a3'), (select id from p where name = 'a2')],
  array[(select id from p where name = 'a1')]), null, 'a save with a new portrait goes through');
select is(pg_temp.rows((select ana from ids)), array['a3', 'a2'], 'removed, published and ordered as saved');
select is(pg_temp.card((select ana from ids)), array['a3.jpg'], 'the refused photo is saved but never on the card');

-- Leaving without saving: the app deletes its drafts.
insert into p values ('a4', pg_temp.pick((select ana from ids), 'a4', 'approved'));
select is(pg_temp.del((select ana from ids), (select id from p where name = 'a4')), null, 'a draft can always go');
select is(pg_temp.rows((select ana from ids)), array['a3', 'a2'], 'the draft is gone');

-- Saved from another device meanwhile: kept, after the list.
insert into p values ('a5', pg_temp.pick((select ana from ids), 'a5', 'approved', p_draft => false));
select is(pg_temp.save((select ana from ids), array[(select id from p where name = 'a2'), (select id from p where name = 'a3')]),
  null, 'a save that does not know a photo');
select is(pg_temp.rows((select ana from ids)), array['a2', 'a3', 'a5'], 'keeps it after the saved ones');

-- MARK: Older app versions

select is(pg_temp.card((select ana from ids)), array['a3.jpg', 'a5.jpg'], 'a photo registered without p_draft is published at once');

-- MARK: Refusals

select is(pg_temp.save((select ana from ids), array[(select id from p where name = 'a3'), (select id from p where name = 'a3')]),
  'invalid_order', 'a photo listed twice');
select is(pg_temp.save((select ana from ids), array[(select id from p where name = 'a3')], array[(select id from p where name = 'a3')]),
  'invalid_order', 'a photo both kept and removed');
select is(pg_temp.save((select ana from ids), array[gen_random_uuid()]), 'not_found', 'a kept photo that is not there');

insert into p values ('b1', pg_temp.pick((select ben from ids), 'b1', 'approved', p_draft => false));
select is(pg_temp.save((select ana from ids), array[(select id from p where name = 'b1')]), 'not_found',
  'someone else''s photo can not be saved');
select is(pg_temp.del((select ana from ids), (select id from p where name = 'b1')), 'not_found',
  'nor deleted');
select is(pg_temp.save((select ana from ids), array[(select id from p where name = 'a3')], array[(select id from p where name = 'b1')]),
  null, 'removing someone else''s photo does nothing');
select is(pg_temp.rows((select ben from ids)), array['b1'], 'their photo is still there');

-- MARK: Deleting the portrait

update public.profiles set onboarded_at = now() where id = (select cleo from ids);
insert into p values ('c1', pg_temp.pick((select cleo from ids), 'c1', 'approved', p_draft => false));
insert into p values ('c2', pg_temp.pick((select cleo from ids), 'c2', 'approved', false, false));
select is(pg_temp.del((select cleo from ids), (select id from p where name = 'c1')), 'portrait_required',
  'an approved photo without a face does not replace the portrait');
update public.profile_media set status = 'pending', face = true where id = (select id from p where name = 'c2');
select is(pg_temp.del((select cleo from ids), (select id from p where name = 'c1')), 'portrait_required',
  'nor does a pending one');
insert into p values ('c3', pg_temp.pick((select cleo from ids), 'c3', 'approved', true));
select is(pg_temp.del((select cleo from ids), (select id from p where name = 'c1')), 'portrait_required',
  'nor an approved draft');
update public.profile_media set status = 'approved', face = null where id = (select id from p where name = 'c2');
select is(pg_temp.del((select cleo from ids), (select id from p where name = 'c1')), null,
  'an approved photo whose face was never checked does');
select is(pg_temp.rows((select cleo from ids)), array['c2', 'c3(d)'], 'the others move up');

-- A portrait the team refuses later: the profile can still change its other photos.
update public.profile_media set status = 'rejected' where id = (select id from p where name = 'c2');
select is(pg_temp.save((select cleo from ids), array[(select id from p where name = 'c2')], array[(select id from p where name = 'c3')]),
  null, 'without a portrait already, a save is not refused');

-- MARK: Drafts nobody saved

insert into p values ('c4', pg_temp.pick((select cleo from ids), 'c4', 'approved'));
insert into p values ('c5', pg_temp.pick((select cleo from ids), 'c5', 'pending'));
update public.profile_media set created_at = now() - interval '8 days' where id = (select id from p where name = 'c4');
update public.profile_media set created_at = now() - interval '8 days', position = 7
  where id = (select id from p where name = 'c2');
select private.purge_media_drafts();
select is(pg_temp.rows((select cleo from ids)), array['c5(d)', 'c2'], 'an old draft goes, a recent one and an old published one stay');
select is((select array_agg(position order by position) from public.profile_media where user_id = (select cleo from ids)),
  array[0, 1]::smallint[], 'positions close up');

select * from finish();
rollback;
