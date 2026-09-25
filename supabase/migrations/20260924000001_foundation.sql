-- Foundation: extensions, private schema, enums, sport catalogue.
--
-- Conventions used across every migration:
-- - Tables live in `public` with RLS on. Clients never write them directly unless a policy says so;
--   writes go through `security definer` RPCs that validate input.
-- - Internals (locations, outbox, helpers) live in `private`, which PostgREST does not expose.
-- - Every function sets `search_path = ''` and schema-qualifies what it touches.
-- - Policies call `(select auth.uid())` so Postgres evaluates it once per query, not once per row.

create extension if not exists postgis with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- Supabase grants broad default privileges on `public`. Start from nothing and grant explicitly.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
-- Postgres also grants EXECUTE to PUBLIC globally, which a per-schema revoke can't remove.
alter default privileges revoke execute on functions from public;

create type public.gender as enum ('woman', 'man', 'nonbinary');
-- Mirrors the app's `Intent` raw values.
create type public.intent as enum ('marathon', 'warmUp', 'sprint', 'squad', 'stretching');
create type public.media_kind as enum ('photo', 'video');
create type public.media_status as enum ('pending', 'approved', 'rejected');
create type public.swipe_action as enum ('like', 'superlike', 'pass');
create type public.session_status as enum ('pending', 'accepted', 'declined', 'countered', 'cancelled');
-- Relative to the proposer: `iTeach` = the proposer introduces the other person to the sport.
create type public.session_discovery as enum ('iTeach', 'theyTeach');
create type public.report_reason as enum ('fake', 'inappropriate_photos', 'harassment', 'spam', 'underage', 'other');

-- Mirrors the app's `Sport` enum raw values. Adding a sport = one insert in a new migration.
create table public.sports (
  id text primary key
);

insert into public.sports (id) values
  ('running'), ('trail'), ('walking'), ('hiking'), ('cycling'), ('spinning'), ('mountainBiking'),
  ('runClub'), ('ultra'), ('gravel'), ('obstacleRace'), ('stairClimbing'),
  ('swimming'), ('openWater'), ('triathlon'), ('rowing'),
  ('surfing'), ('sailing'), ('skateboarding'), ('kitesurf'), ('wingFoil'), ('paddleBoard'), ('kayak'),
  ('skiing'), ('crossCountrySki'), ('snowboarding'), ('skiTouring'), ('iceSkating'),
  ('hyrox'), ('strength'), ('functional'), ('crossfit'), ('hiit'), ('calisthenics'), ('jumpRope'), ('parkour'),
  ('yoga'), ('hotYoga'), ('pilates'), ('reformer'), ('barre'), ('mobility'), ('taichi'), ('dance'), ('gymnastics'),
  ('boxing'), ('kickboxing'), ('martialArts'), ('bjj'), ('fencing'),
  ('padel'), ('tennis'), ('beachTennis'), ('badminton'), ('squash'), ('tableTennis'), ('pickleball'),
  ('football'), ('basketball'), ('volleyball'), ('beachVolley'), ('rugby'), ('handball'), ('hockey'), ('ultimate'), ('spikeball'),
  ('climbing'), ('bouldering'), ('golf'), ('equestrian'), ('archery');

alter table public.sports enable row level security;
create policy sports_read on public.sports for select to anon, authenticated using (true);
grant select on public.sports to anon, authenticated;

-- Shared helper: raise a client-facing error with a stable machine code in HINT.
-- The app switches on `hint`; `message` is for logs.
create function private.fail(p_code text, p_message text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception '%', p_message using errcode = 'P0001', hint = p_code;
end;
$$;

create function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
