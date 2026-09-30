-- The area a profile shows ("Paris 11", "Lyon 4", "Annecy"), found by the server from the blurred position the
-- app sends, so iPhone, Android and web give the same name, and no phone needs its own geocoder (Android
-- without Google Play services has none).
--
-- private.areas holds the official boundaries of France: every commune, with Paris, Lyon and Marseille split
-- into their arrondissements. Loaded by scripts/load-areas.ts (Etalab and geo.api.gouv.fr, Licence Ouverte),
-- not by this migration: the data is tens of megabytes and changes once a year.
--
-- area_at answers with the area the point falls in, or the nearest one within 3 km: a blurred position is the
-- centre of a ~1 km cell, which can land in the sea, a lake or just across a border. Nothing within 3 km
-- (outside France, or areas not loaded yet): null, and the app falls back to its own resolver.

create table private.areas (
  -- INSEE code of the commune or arrondissement.
  code text primary key,
  name text not null check (char_length(name) between 1 and 60),
  city text not null check (char_length(city) between 1 and 60),
  geom extensions.geometry(MultiPolygon, 4326) not null
);

create index areas_geom_idx on private.areas using gist (geom);

create function public.area_at(p_lat double precision, p_lng double precision)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_here extensions.geometry;
  v_area jsonb;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    perform private.fail('invalid_location', 'coordinates out of range');
  end if;
  v_here := extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326);
  -- The box (0.05°, 3.5 to 5.5 km) uses the index; the distance, in metres, decides.
  select jsonb_build_object('name', a.name, 'city', a.city)
    into v_area
    from private.areas a
    where a.geom operator(extensions.&&) extensions.st_expand(v_here, 0.05)
      and extensions.st_dwithin(a.geom::extensions.geography, v_here::extensions.geography, 3000)
    order by extensions.st_distance(a.geom::extensions.geography, v_here::extensions.geography), a.code
    limit 1;
  return v_area;
end;
$$;

grant execute on function public.area_at(double precision, double precision) to authenticated;
