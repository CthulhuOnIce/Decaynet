-- =============================================================================
-- Decaynet :: 0016 address search
--
-- The global search box also matches street addresses, so "577 Washington"
-- finds the building, jumps to it on the map and links to its page. The
-- address is rendered with the site's format, and an address without a linked
-- street falls back to the raw text from the source.
-- =============================================================================

create or replace function public.search_addresses(
  p_q text,
  p_limit integer default 20
) returns table (
  address_id uuid,
  entity_id uuid,
  entity_slug text,
  entity_kind text,
  entity_name text,
  street_id uuid,
  street_name text,
  house_number text,
  raw_address text,
  formatted text,
  lon double precision,
  lat double precision,
  score real
)
language sql stable set search_path = public, extensions as $$
  with q as (select btrim(p_q) as q),
  base as (
    select a.id, a.entity_id, a.street_id, a.house_number, a.raw_address,
           public.name_at(a.street_id, current_date) as street_name,
           coalesce(
             case when a.street_id is not null
               then public.format_address(a.house_number, public.name_at(a.street_id, current_date)) end,
             nullif(btrim(a.raw_address), '')
           ) as formatted
      from public.addresses a
  ),
  scored as (
    select b.*,
           (similarity(b.formatted, q.q)
            + case when b.formatted ilike q.q || '%' then 1
                   when b.formatted ilike '% ' || q.q || '%' then 0.6
                   else 0 end)::real as score
      from base b, q
     where b.formatted is not null
       and (b.formatted ilike '%' || q.q || '%' or b.formatted % q.q)
  ),
  ranked as (
    select distinct on (s.entity_id, lower(s.formatted))
           s.id, s.entity_id, s.street_id, s.house_number, s.raw_address,
           s.street_name, s.formatted, s.score
      from scored s, q
     -- A bare street name already finds the street page; require a house number
     -- (or a very close match) before listing every address on it.
     where q.q ~ '[0-9]' or s.score >= 0.4
     order by s.entity_id, lower(s.formatted), s.score desc
     limit 250
  )
  select r.id, e.id, e.slug, e.kind, e.name, r.street_id, r.street_name,
         r.house_number, r.raw_address, r.formatted,
         extensions.st_x(extensions.st_centroid(g.geom))::double precision,
         extensions.st_y(extensions.st_centroid(g.geom))::double precision,
         r.score
    from ranked r
    join public.entities e on e.id = r.entity_id
    left join lateral (
      select coalesce(public.locate(r.entity_id), public.locate(r.street_id)) as geom
    ) g on true
   order by r.score desc, r.formatted
   limit p_limit
$$;
