-- =============================================================================
-- Decaynet :: 0054 street corners, explained
--
-- The workbench's "pin a street corner by name" was hit or miss, and when it
-- missed it didn't say why. street_lookup says, for each of the two streets,
-- which pages it matched (and whether they have a shape to cross), offers
-- streets with similar names when one matched nothing, gives the shapes so
-- the workbench can draw what it found, and, when the streets are found but
-- don't meet, the closest they come. It also finds more:
--   * streets mapped as areas (a road's outline), not only as centrelines
--   * streets that stop short of each other by up to 60 m (was 25)
--   * "Broadway (Gary)", "The Strand": brackets and a leading "the" are ignored
-- =============================================================================

create or replace function public.street_key(p_name text, p_core boolean default false)
returns text
language plpgsql immutable set search_path = public as $$
declare
  w text[];
  i int;
  ord constant text[] := array['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh', 'eighth', 'ninth', 'tenth',
    'eleventh', 'twelfth', 'thirteenth', 'fourteenth', 'fifteenth', 'sixteenth', 'seventeenth', 'eighteenth', 'nineteenth', 'twentieth'];
  sfx constant text[] := array['1st', '2nd', '3rd', '4th', '5th', '6th', '7th', '8th', '9th', '10th',
    '11th', '12th', '13th', '14th', '15th', '16th', '17th', '18th', '19th', '20th'];
  k int;
begin
  -- "Broadway (Gary)" → "Broadway"; "The Strand" → "Strand"
  w := regexp_split_to_array(btrim(regexp_replace(lower(regexp_replace(coalesce(p_name, ''), '\([^)]*\)', ' ', 'g')), '[^a-z0-9]+', ' ', 'g')), ' ');
  if w = array[''] then return ''; end if;
  if array_length(w, 1) > 1 and w[1] = 'the' then w := w[2:]; end if;
  for i in 1 .. array_length(w, 1) loop
    k := array_position(ord, w[i]);
    if k is not null then w[i] := sfx[k]; continue; end if;
    w[i] := case w[i]
      when 'avenue' then 'ave' when 'av' then 'ave' when 'street' then 'st' when 'str' then 'st'
      when 'boulevard' then 'blvd' when 'road' then 'rd' when 'drive' then 'dr' when 'place' then 'pl'
      when 'court' then 'ct' when 'lane' then 'ln' when 'highway' then 'hwy' when 'parkway' then 'pkwy'
      when 'terrace' then 'ter' when 'alley' then 'aly' when 'square' then 'sq' when 'circle' then 'cir'
      when 'north' then 'n' when 'south' then 's' when 'east' then 'e' when 'west' then 'w'
      else w[i] end;
  end loop;
  if p_core and array_length(w, 1) > 1 then
    if w[1] in ('n', 's', 'e', 'w') then w := w[2:]; end if;
    if array_length(w, 1) > 1 and w[array_length(w, 1)] in ('ave', 'st', 'blvd', 'rd', 'dr', 'pl', 'ct', 'ln', 'hwy', 'pkwy', 'ter', 'aly', 'sq', 'cir', 'way') then
      w := w[1:array_length(w, 1) - 1];
    end if;
  end if;
  return array_to_string(w, ' ');
end;
$$;

/** Street names (current or historic) most like a name that matched none: at most 4. */
create or replace function public.street_names_like(p_name text)
returns jsonb
language sql stable security invoker set search_path = public, extensions as $$
  select coalesce(jsonb_agg(nm order by score desc), '[]')
    from (
      select nm, max(score) score
        from (
          select n.nm, similarity(public.street_key(n.nm), public.street_key(p_name)) score
            from public.entities e
            cross join lateral (select e.name nm union select x.name from public.entity_names x where x.entity_id = e.id) n
           where e.kind = 'street'
        ) x
       where score >= 0.3
       group by nm
       order by max(score) desc
       limit 4
    ) y;
$$;

/**
 * Where two streets cross, from the streets mapped in the wiki, and why not when they don't.
 * p_a, p_b: street names (any name the street had); p_at: the year the sheet shows (shapes of that
 * year win); p_near: {lon, lat} to rank by (the map's view).
 * Returns {
 *   hits: [{lon, lat, a: {id, slug, name}, b: {…}, gap_m, then}]  nearest first, at most 6; streets
 *         that stop short (≤ 60 m) count, at the middle of the gap
 *   a, b: {pages: [{id, slug, name, shapes}]}   the streets each name matched; shapes: how many it has to cross
 *   suggest: {a: [name], b: [name]}             for a name that matched nothing: streets named like it
 *   nearest: {lon, lat, gap_m} | null           found both, no crossing: the middle of their closest approach (≤ 2 km)
 *   lines: {a: GeoJSON, b: GeoJSON}             the matched streets' shapes (as lines), near the view, to draw
 * }
 */
create or replace function public.street_lookup(p_a text, p_b text, p_at date default null, p_near jsonb default null)
returns jsonb
language sql stable security invoker set search_path = public, extensions as $$
  with
  q as (
    select case when jsonb_typeof(p_near -> 'lon') = 'number' and jsonb_typeof(p_near -> 'lat') = 'number'
                then st_setsrid(st_makepoint((p_near ->> 'lon')::float8, (p_near ->> 'lat')::float8), 4326) end near
  ),
  typed as (
    select 'a' side, p_a nm, public.street_key(p_a) k, public.street_key(p_a, true) c
    union all
    select 'b', p_b, public.street_key(p_b), public.street_key(p_b, true)
  ),
  -- the streets each name matched, by any name they had; an exact match beats one on the core
  -- name alone ("Broadway" for "Broadway Street")
  streets as materialized (
    select t.side, e.id, e.slug, e.name, min(case when public.street_key(n.nm) = t.k then 0 else 1 end) rank
      from typed t
      cross join public.entities e
      cross join lateral (select e.name nm union select x.name from public.entity_names x where x.entity_id = e.id) n
     where e.kind = 'street' and t.k <> ''
       and (public.street_key(n.nm) = t.k or public.street_key(n.nm, true) = t.c)
     group by t.side, e.id, e.slug, e.name
  ),
  -- their shapes to cross: centrelines, and streets mapped as areas
  shapes as materialized (
    select s.side, s.id, s.rank, g.geom, (p_at is not null and g.valid @> p_at) then_
      from streets s join public.entity_geometries g on g.entity_id = s.id
     where g.role in ('centerline', 'shape', 'footprint', 'boundary') and st_dimension(g.geom) in (1, 2)
  ),
  pairs as (
    select a.id aid, b.id bid, a.geom ga, b.geom gb, (a.then_ and b.then_) then_, a.rank + b.rank rank
      from shapes a join shapes b on a.side = 'a' and b.side = 'b' and a.id <> b.id
     where st_dwithin(a.geom::geography, b.geom::geography, 60)
  ),
  -- where they cross (each crossing, when more than once), or the middle of a gap of up to 60 m
  spots as (
    select p.*, st_centroid(d.geom) pt, 0::float8 gap
      from pairs p cross join lateral st_dump(st_intersection(p.ga, p.gb)) d
     where st_intersects(p.ga, p.gb)
    union all
    select p.*, st_lineinterpolatepoint(st_shortestline(p.ga, p.gb), 0.5), st_distance(p.ga::geography, p.gb::geography)
      from pairs p
     where not st_intersects(p.ga, p.gb)
  ),
  one_each as (
    select distinct on (round(st_x(pt)::numeric, 4), round(st_y(pt)::numeric, 4)) s.*
      from spots s
     order by round(st_x(pt)::numeric, 4), round(st_y(pt)::numeric, 4), s.then_ desc, s.gap, s.rank
  ),
  top as (
    select o.*, row_number() over (
             order by o.then_ desc, o.rank, (o.gap > 0),
                      case when q.near is not null then st_distance(o.pt::geography, q.near::geography) end nulls last, o.gap) ord
      from one_each o, q
     order by ord
     limit 6
  ),
  hits as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'lon', round(st_x(t.pt)::numeric, 7), 'lat', round(st_y(t.pt)::numeric, 7),
             'a', jsonb_build_object('id', ea.id, 'slug', ea.slug, 'name', ea.name),
             'b', jsonb_build_object('id', eb.id, 'slug', eb.slug, 'name', eb.name),
             'gap_m', round(t.gap::numeric, 1), 'then', t.then_) order by t.ord), '[]') h
      from top t join public.entities ea on ea.id = t.aid join public.entities eb on eb.id = t.bid
  ),
  -- found both, no crossing: the middle of their closest approach (within 2 km)
  nearest as (
    select jsonb_build_object('lon', round(st_x(m)::numeric, 7), 'lat', round(st_y(m)::numeric, 7), 'gap_m', round(d::numeric)) n
      from (
        select st_lineinterpolatepoint(st_shortestline(a.geom, b.geom), 0.5) m, st_distance(a.geom::geography, b.geom::geography) d
          from shapes a join shapes b on a.side = 'a' and b.side = 'b' and a.id <> b.id
         where st_dwithin(a.geom::geography, b.geom::geography, 2000)
         order by 2
         limit 1
      ) x
     where not exists (select 1 from top)
  ),
  side as (
    select t.side,
           jsonb_build_object('pages', coalesce((
             select jsonb_agg(jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name,
                                                 'shapes', (select count(*) from shapes x where x.side = s.side and x.id = s.id))
                              order by s.rank, s.name)
               from streets s where s.side = t.side), '[]')) pages,
           -- a name that matched nothing: streets named like it
           case when not exists (select 1 from streets s where s.side = t.side) then public.street_names_like(t.nm) else '[]'::jsonb end suggest,
           -- the shapes found, as lines, within 5 km of the view, to draw on the map
           (select st_asgeojson(st_simplify(st_collect(case when st_dimension(x.geom) = 2 then st_boundary(x.geom) else x.geom end), 0.00001), 6)::jsonb
              from shapes x, q
             where x.side = t.side and (q.near is null or st_dwithin(x.geom::geography, q.near::geography, 5000))) lines
      from typed t
  )
  select jsonb_build_object(
    'hits', (select h from hits),
    'a', (select pages from side where side = 'a'),
    'b', (select pages from side where side = 'b'),
    'suggest', jsonb_build_object('a', (select suggest from side where side = 'a'), 'b', (select suggest from side where side = 'b')),
    'nearest', (select n from nearest),
    'lines', jsonb_build_object('a', (select lines from side where side = 'a'), 'b', (select lines from side where side = 'b')));
$$;

grant execute on function public.street_lookup(text, text, date, jsonb) to anon, authenticated;
grant execute on function public.street_names_like(text) to anon, authenticated;
