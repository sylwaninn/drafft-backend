-- Private media (20260928000141): URLs are signed like the media Worker checks them, and only for what
-- the caller may see (not paused, not on hold, not blocked; chat media for match members only).
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

-- The same Vault secrets as an environment, for this transaction only.
delete from vault.secrets where name in ('media_base_url', 'media_signing_key');
select vault.create_secret('https://media.test/', 'media_base_url');
select vault.create_secret('test-signing-key', 'media_signing_key');

-- MARK: Signature

-- Same vector as cloudflare/media-worker/src/signature_test.ts and _shared/media_url_test.ts.
select is(
  private.sign_media_key('u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/a.jpg', 'https://media.test',
    convert_to('test-signing-key', 'UTF8'), 1700000000),
  'https://media.test/u/0b6f1f5e-8f0c-4a5e-9d3b-2f8a1c7e4d10/photos/a.jpg?exp=1700000000&sig=I1YxT7hgXlCCw0Jkq79-oMnamOJOSSZn9MRs6E3d3Uw',
  'the signature is HMAC-SHA256 of key and expiry, base64url without padding');
select is(private.sign_media_key('u/x/photos/a.jpg', 'https://media.test', null, 1),
  'https://media.test/u/x/photos/a.jpg', 'no signing key yet: the public URL, for the switch');
select is(private.sign_media_key('u/x/photos/a.jpg', null, 'k'::bytea, 1), null, 'no base URL: no URL');
select ok((select exp between extract(epoch from now())::bigint + 3600 and extract(epoch from now())::bigint + 4500
  from private.media_signer()), 'links last between one hour and one hour and a quarter');
select is((select base from private.media_signer()), 'https://media.test', 'the base URL loses its trailing slash');

-- MARK: Who gets links

create function pg_temp.person(p_name text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role, instance_id)
  values (v_id, lower(p_name) || '@test.dev', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
  update public.profiles
    set name = p_name, gender = 'woman', birthdate = current_date - make_interval(years => 30, days => 10),
        voice_intro_key = 'u/' || v_id || '/voice/v.m4a', voice_duration = 3
    where id = v_id;
  insert into public.profile_sports (user_id, sport_id, per_week, position) values (v_id, 'running', 2, 0);
  insert into public.profile_media (user_id, key, position, width, height, status)
    values (v_id, 'u/' || v_id || '/photos/1.jpg', 0, 1200, 1600, 'approved');
  insert into private.locations (user_id, geo)
    values (v_id, extensions.st_setsrid(extensions.st_makepoint(2.35, 48.86), 4326)::extensions.geography);
  update public.profiles set onboarded_at = now() where id = v_id;
  return v_id;
end $$;

create function pg_temp.login(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- The URL of the first photo of a card that get_cards returns to the caller.
create function pg_temp.photo_url(p_user uuid) returns text language sql as $$
  select c -> 'media' -> 0 ->> 'url' from public.get_cards(array[p_user]) c;
$$;

grant execute on all functions in schema pg_temp to authenticated;

create temp table ids as select
  pg_temp.person('Ana') as ana, pg_temp.person('Ben') as ben, pg_temp.person('Cleo') as cleo,
  pg_temp.person('Dan') as dan, pg_temp.person('Eve') as eve;
grant select on ids to authenticated;

-- Ana matches Ben, Cleo and Dan, and likes Eve.
set local role authenticated;
select pg_temp.login((select ben from ids));
select public.swipe((select ana from ids), 'like');
select pg_temp.login((select cleo from ids));
select public.swipe((select ana from ids), 'like');
select pg_temp.login((select dan from ids));
select public.swipe((select ana from ids), 'like');
select pg_temp.login((select ana from ids));
select public.swipe(id, 'like') from (select unnest(array[ben, cleo, dan, eve]) as id from ids) x;

select is((select count(*) from public.my_matches() m where m #>> '{profile,media,0,url}' like 'https://media.test/u/%?exp=%&sig=%'),
  3::bigint, 'matches come with signed photo URLs');
select ok((select bool_and(m #>> '{profile,voiceIntro,url}' like 'https://media.test/u/%/voice/v.m4a?exp=%')
  from public.my_matches() m), 'and a signed voice intro URL');
select ok((select bool_and(m #>> '{profile,media,0,key}' is not null) from public.my_matches() m),
  'keys stay, for apps that still build URLs');
select ok(pg_temp.photo_url((select eve from ids)) is not null, 'a card Ana liked is signed too');

-- Cleo pauses, Dan is banned, Eve blocks Ana.
reset role;
update public.profiles set paused = true where id = (select cleo from ids);
update public.profiles set moderation = 'banned' where id = (select dan from ids);
insert into public.blocks (blocker, blocked) select eve, ana from ids;
set local role authenticated;
select pg_temp.login((select ana from ids));

select is(pg_temp.photo_url((select cleo from ids)), null, 'no link to a paused person');
select is(pg_temp.photo_url((select dan from ids)), null, 'no link to a banned person');
select is((select count(*) from public.get_cards(array[(select eve from ids)])), 0::bigint,
  'no card at all across a block');
select is(pg_temp.photo_url((select ben from ids)), (select m #>> '{profile,media,0,url}' from public.my_matches() m
  where m #>> '{profile,id}' = (select ben::text from ids)), 'Ben still gets through');

-- An account on hold sees nobody's media.
reset role;
update public.profiles set moderation = 'review' where id = (select ana from ids);
set local role authenticated;
select is(pg_temp.photo_url((select ben from ids)), null, 'a viewer on hold gets no links');
reset role;
update public.profiles set moderation = null where id = (select ana from ids);
set local role authenticated;

-- MARK: media_urls: own media and chat media of a match

select pg_temp.login((select ana from ids));
select ok((public.media_urls(array['u/' || (select ana from ids) || '/photos/1.jpg'])
  ->> ('u/' || (select ana from ids) || '/photos/1.jpg')) like '%&sig=%', 'your own media, always');
select is(public.media_urls(array['u/' || (select ben from ids) || '/chat/c.jpg']) ? ('u/' || (select ben from ids) || '/chat/c.jpg'),
  true, 'chat media of a match');
select is(public.media_urls(array['u/' || (select ben from ids) || '/photos/1.jpg']), '{}'::jsonb,
  'not their profile media: that goes through their card');
select is(public.media_urls(array['u/' || (select cleo from ids) || '/chat/c.jpg', 'u/' || (select eve from ids) || '/chat/c.jpg']),
  '{}'::jsonb, 'no chat media from a paused person or across a block');
select is(public.media_urls(array['u/' || (select ana from ids) || '/photos/../x.jpg', 'not-a-key']), '{}'::jsonb,
  'malformed keys are ignored');
select pg_temp.login((select eve from ids));
select is(public.media_urls(array['u/' || (select ben from ids) || '/chat/c.jpg']), '{}'::jsonb,
  'no chat media outside a match');

select * from finish();
rollback;
