-- =============================================================================
-- Decaynet :: 0053 street crossings
--
-- For the workbench's scan alignment: "Broadway & 5th Ave" → where those two
-- streets meet, from the wiki's own street centrelines (so a street that's
-- gone, or was renamed, is found by any name it had). Not every street is
-- mapped as a page: the workbench falls back to OpenStreetMap for those.
-- =============================================================================

/** A street name reduced to a key that ignores spelling: "N. Fifth Avenue" and "north 5th ave" both
 *  give "n 5th ave". p_core drops the leading direction and the trailing street type too ("5th"). */
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
  w := regexp_split_to_array(btrim(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', ' ', 'g')), ' ');
  if w = array[''] then return ''; end if;
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

/** Where two streets cross, from the streets mapped in the wiki.
 *  p_a, p_b: street names (any name the street had); p_at: the year the sheet shows (centrelines of
 *  that year win, any year's do otherwise); p_near: {lon, lat} to rank by (the map's view).
 *  Streets that stop just short of each other (≤ 25 m) count, at the middle of the gap.
 *  Returns [{lon, lat, a: {id, slug, name}, b: {…}, gap_m, then: bool}] nearest first, at most 6. */
create or replace function public.street_crossings(p_a text, p_b text, p_at date default null, p_near jsonb default null)
returns jsonb
language sql stable security invoker set search_path = public, extensions as $$
  with
  q as (
    select public.street_key(p_a) ka, public.street_key(p_a, true) ca,
           public.street_key(p_b) kb, public.street_key(p_b, true) cb,
           case when jsonb_typeof(p_near -> 'lon') = 'number' and jsonb_typeof(p_near -> 'lat') = 'number'
                then st_setsrid(st_makepoint((p_near ->> 'lon')::float8, (p_near ->> 'lat')::float8), 4326) end near
  ),
  -- every street with a name (current or historic) matching; an exact match beats one on the core
  -- name alone ("Broadway" for "Broadway Street")
  named as (
    select e.id, e.slug, e.name, n.nm, 'a' side,
           case when public.street_key(n.nm) = q.ka then 0 else 1 end rank
      from q, public.entities e
      cross join lateral (select e.name nm union select x.name from public.entity_names x where x.entity_id = e.id) n
     where e.kind = 'street' and q.ka <> ''
       and (public.street_key(n.nm) = q.ka or public.street_key(n.nm, true) = q.ca)
    union all
    select e.id, e.slug, e.name, n.nm, 'b',
           case when public.street_key(n.nm) = q.kb then 0 else 1 end
      from q, public.entities e
      cross join lateral (select e.name nm union select x.name from public.entity_names x where x.entity_id = e.id) n
     where e.kind = 'street' and q.kb <> ''
       and (public.street_key(n.nm) = q.kb or public.street_key(n.nm, true) = q.cb)
  ),
  streets as (
    select id, slug, name, side, min(rank) rank from named group by id, slug, name, side
  ),
  lines as (
    select s.*, g.geom, (p_at is not null and g.valid @> p_at) then_
      from streets s join public.entity_geometries g on g.entity_id = s.id
     where g.role in ('centerline', 'shape') and st_dimension(g.geom) = 1
  ),
  pairs as (
    select a.id aid, a.slug aslug, a.name aname, b.id bid, b.slug bslug, b.name bname,
           a.rank + b.rank rank, (a.then_ and b.then_) then_, a.geom ga, b.geom gb
      from lines a join lines b on a.side = 'a' and b.side = 'b' and a.id <> b.id
     where st_dwithin(a.geom::geography, b.geom::geography, 25)
  ),
  spots as (
    -- where they cross (each crossing, when they cross more than once) …
    select p.*, st_centroid(d.geom) pt, 0::float8 gap
      from pairs p cross join lateral st_dump(st_intersection(p.ga, p.gb)) d
     where st_intersects(p.ga, p.gb)
    union all
    -- … or the middle of the gap where one stops short of the other
    select p.*, st_lineinterpolatepoint(st_shortestline(p.ga, p.gb), 0.5),
           st_distance(p.ga::geography, p.gb::geography)
      from pairs p
     where not st_intersects(p.ga, p.gb)
  ),
  ranked as (
    select distinct on (round(st_x(pt)::numeric, 5), round(st_y(pt)::numeric, 5)) s.*
      from spots s, q
     order by round(st_x(pt)::numeric, 5), round(st_y(pt)::numeric, 5), s.then_ desc, s.gap, s.rank
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'lon', round(st_x(pt)::numeric, 7), 'lat', round(st_y(pt)::numeric, 7),
           'a', jsonb_build_object('id', aid, 'slug', aslug, 'name', aname),
           'b', jsonb_build_object('id', bid, 'slug', bslug, 'name', bname),
           'gap_m', round(gap::numeric, 1), 'then', then_)
         order by ord), '[]')
    from (
      select r.*, row_number() over (
               order by r.then_ desc, r.rank, (r.gap > 0),
                        case when q.near is not null then st_distance(r.pt::geography, q.near::geography) end nulls last) ord
        from ranked r, q
      order by ord
      limit 6
    ) top;
$$;
grant execute on function public.street_key(text, boolean) to anon, authenticated;
grant execute on function public.street_crossings(text, text, date, jsonb) to anon, authenticated;
