-- area_at: the area a blurred position falls in, the nearest within 3 km, or null.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

-- Only two neighbouring squares, 0.04° wide (about 3 km), side by side: none of the real areas a local
-- database may have loaded.
delete from private.areas;
create function pg_temp.square(p_code text, p_name text, p_west float8) returns void language sql as $$
  insert into private.areas (code, name, city, geom) values (p_code, p_name, 'Testville',
    extensions.st_multi(extensions.st_makeenvelope(p_west, 48.84, p_west + 0.04, 48.86, 4326)));
$$;
select pg_temp.square('T0001', 'Testville 1', 2.30);
select pg_temp.square('T0002', 'Testville 2', 2.34);

set local role authenticated;

select is(public.area_at(48.85, 2.32), '{"name": "Testville 1", "city": "Testville"}'::jsonb,
  'a point inside an area gets that area');
select is(public.area_at(48.85, 2.36) ->> 'name', 'Testville 2', 'next door, the other one');
select is(public.area_at(48.865, 2.335) ->> 'name', 'Testville 1',
  'just outside (a cell centre over water): the nearest area');
select is(public.area_at(48.95, 2.32), null, 'more than 3 km from any area: nothing');
select is(public.area_at(45.76, 4.83), null, 'an area not loaded: nothing, the app falls back');
select throws_ok($$select public.area_at(91, 2.32)$$, 'P0001', 'coordinates out of range',
  'coordinates out of range are refused');

reset role;
select is(has_function_privilege('anon', 'public.area_at(double precision, double precision)', 'execute'), false,
  'signed out: not allowed');

select * from finish();
rollback;
