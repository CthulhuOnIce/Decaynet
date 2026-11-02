-- =============================================================================
-- Decaynet :: 0023 places read as their occupants
--
-- A building is usually known by whoever is in it: "Joe's Diner", not "12 Main
-- Street". On the map, a building, site or parcel occupied by someone at the
-- selected date (the "occupies" link, not residents) is now labelled with the
-- occupant; the place's own name goes underneath in small type unless one
-- name contains the other ("Gary Land Company" / "Gary Land Company
-- Building"). Storefronts and suites (spaces) already showed their tenant.
-- =============================================================================

/*
 * Who occupies a place on a date, as a short label: the most recent occupant's
 * name then, plus "+N" for any others ("Joe's Diner +1"). Null when empty.
 * Residents ("lived at") don't count: houses keep their own names.
 * Runs as the caller, so private occupants stay hidden from those who can't
 * see them.
 */
create or replace function public.occupant_label(p_place uuid, p_at date default current_date)
returns text language sql stable set search_path = public as $$
  select case when count(*) = 0 then null
              when count(*) = 1 then min(o.name)
              else (array_agg(o.name order by o.ord))[1] || ' +' || (count(*) - 1)
         end
    from (select public.name_at(r.subject_id, coalesce(p_at, current_date)) as name,
                 row_number() over (order by r.valid_from desc nulls last, r.created_at) as ord
            from public.relations r
           where r.object_id = p_place
             and r.predicate = 'occupies'
             and r.valid @> coalesce(p_at, current_date)) o
$$;

comment on function public.occupant_label(uuid, date) is
  'Short label for who occupies a place on a date ("Joe''s Diner", "Joe''s Diner +1"), or null.';

-- The map, with the occupant on buildings, sites and parcels (otherwise as in 0010)
create or replace function public.map_snapshot(
  p_at date default current_date,
  p_kinds text[] default null,
  p_west double precision default null,
  p_south double precision default null,
  p_east double precision default null,
  p_north double precision default null,
  p_ghosts boolean default true,
  p_tag text default null
) returns jsonb
language sql stable set search_path = public, extensions as $$
  with bbox as (
    select case when p_west is null then null
                else st_makeenvelope(p_west, p_south, p_east, p_north, 4326) end as env
  ),
  live as (
    select distinct on (g.entity_id, g.role)
           g.entity_id, g.role, g.geom, g.confidence, false as ghost
      from public.entity_geometries g
      join public.entities e on e.id = g.entity_id
     cross join bbox
     where g.role <> 'viewpoint'
       and e.kind not in ('event', 'media')
       and (p_kinds is null or e.kind = any (p_kinds))
       and e.lifespan @> p_at
       and g.valid @> p_at
       and (bbox.env is null or g.geom && bbox.env)
     order by g.entity_id, g.role, g.valid_from desc nulls last
  ),
  ghosts as (
    select distinct on (g.entity_id)
           g.entity_id, g.role, g.geom, g.confidence, true as ghost
      from public.entity_geometries g
      join public.entities e on e.id = g.entity_id
     cross join bbox
     where p_ghosts
       and g.role <> 'viewpoint'
       and e.kind in ('building', 'street', 'site', 'infrastructure', 'parcel', 'water', 'landform')
       and (p_kinds is null or e.kind = any (p_kinds))
       and upper(e.lifespan) <= p_at
       and (bbox.env is null or g.geom && bbox.env)
     order by g.entity_id, g.valid_from desc nulls last
  ),
  tagged as (
    select distinct et.entity_id
      from public.tags root
      join public.tag_tree tt on tt.ancestor_id = root.id
      join public.entity_tags et on et.tag_id = tt.id
     where root.slug = p_tag and et.valid @> p_at
  ),
  feats as (
    select * from (select * from live union all select * from ghosts) x
     where p_tag is null
        or x.entity_id in (select entity_id from tagged)
        -- a tagged tenant lights up the space it occupies
        or x.entity_id in (select r.object_id from public.relations r
                            where r.predicate = 'occupies' and r.valid @> p_at
                              and r.subject_id in (select entity_id from tagged))
  )
  select jsonb_build_object(
    'type', 'FeatureCollection',
    'at', p_at,
    'features', coalesce(jsonb_agg(jsonb_build_object(
      'type', 'Feature',
      'id', f.entity_id,
      'geometry', st_asgeojson(f.geom, 7)::jsonb,
      'properties', jsonb_build_object(
        'id', e.id,
        'slug', e.slug,
        'kind', e.kind,
        'role', f.role,
        'name', public.name_at(e.id, p_at),
        'status', st.id,
        'status_label', st.label,
        'decay', coalesce(st.decay_level, 0),
        'color', coalesce(st.color, k.color),
        'kind_color', k.color,
        'ghost', f.ghost,
        'extant', not f.ghost and coalesce(st.is_extant, true),
        'confidence', f.confidence
      ) || case when e.kind = 'space' then jsonb_build_object(
        'tenant', public.tenants_at(e.id, p_at),
        'floor', public.attribute_at(e.id, 'floor', p_at),
        'vacant_space', public.tenants_at(e.id, p_at) is null
      ) when o.occupant is not null then jsonb_strip_nulls(jsonb_build_object(
        'occupant', o.occupant,
        -- the place's own name, shown under the occupant unless one name contains the other
        -- ("Gary Land Company" in "Gary Land Company Building")
        'place_name', case when not (strpos(lower(o.place), lower(split_part(o.occupant, ' +', 1))) > 0
                                     or strpos(lower(split_part(o.occupant, ' +', 1)), lower(o.place)) > 0)
                           then o.place end
      )) else '{}'::jsonb end
    ) order by k.sort), '[]'::jsonb)
  )
  from feats f
  join public.entities e on e.id = f.entity_id
  join public.entity_kinds k on k.id = e.kind
  left join public.lifecycle_statuses st on st.id = public.status_at(e.id, p_at)
  left join lateral (
    select public.occupant_label(e.id, p_at) as occupant, public.name_at(e.id, p_at) as place
     where e.kind in ('building', 'site', 'parcel') and not f.ghost
  ) o on true
$$;

