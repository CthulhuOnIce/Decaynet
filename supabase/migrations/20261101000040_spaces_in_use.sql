-- =============================================================================
-- Decaynet :: 0040 spaces in use aren't vacant
--
-- A space (storefront, suite, hall) with no tenant linked was shown as vacant
-- even when its condition said it was in use. Now a space in use for the date
-- (Active, Restored, Repurposed...: a standing condition at decay level 0, not
-- under construction or proposed) counts as occupied, by a tenant that has no
-- page (yet): on the map its own name labels it and it isn't shaded vacant;
-- building_spaces() reports in_use so the building page can say so. A space
-- with no condition, or marked Vacant, is vacant as before.
-- =============================================================================

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
        'name', nm.name,
        'status', st.id,
        'status_label', st.label,
        'decay', coalesce(st.decay_level, 0),
        'color', case when nc.unstated then nc.color else coalesce(st.color, k.color) end,
        -- plotted but no condition for this date: work to do (coloured by the site setting)
        'no_status', nc.unstated,
        -- for colouring by article status instead
        'article_status', ar.status,
        'article_color', coalesce(ars.color, '#6f6457'),
        'kind_color', k.color,
        'ghost', f.ghost,
        'extant', not f.ghost and coalesce(st.is_extant, true),
        'confidence', f.confidence
      ) || case when e.kind = 'space' then jsonb_build_object(
        -- a space in use with no tenant linked: its own name stands in for the tenant (not "vacant")
        'tenant', coalesce(public.tenants_at(e.id, p_at), case when nc.in_use then nm.name end),
        'floor', public.attribute_at(e.id, 'floor', p_at),
        'vacant_space', public.tenants_at(e.id, p_at) is null and not nc.in_use
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
  -- name_at(), status_at() and occupant_label(), written out as joins (0033): one statement,
  -- so the read rules' checks run once per map rather than once per feature
  cross join lateral (
    select coalesce(
      (select n.name from public.entity_names n
        where n.entity_id = e.id and n.valid @> p_at
          and n.name_type in ('official', 'common', 'historic')
        order by n.valid_from desc nulls last,
                 array_position(array['official', 'common', 'historic'], n.name_type)
        limit 1),
      e.name) as name
  ) nm
  left join lateral (
    select s.status from public.entity_states s
     where s.entity_id = e.id and s.valid @> p_at
     order by s.valid_from desc nulls last
     limit 1
  ) sa on true
  left join public.lifecycle_statuses st on st.id = sa.status
  cross join lateral (
    select (not f.ghost and sa.status is null and e.kind in ('building', 'site', 'infrastructure')
            and (select ss.unstated_color from public.site_settings ss) is not null) as unstated,
           (select ss.unstated_color from public.site_settings ss) as color,
           coalesce(st.is_extant and st.decay_level = 0 and st.id not in ('under_construction', 'proposed'), false) as in_use
  ) nc
  left join public.articles ar on ar.entity_id = e.id
  left join public.article_statuses ars on ars.id = ar.status
  left join lateral (
    select case when count(*) = 0 then null
                when count(*) = 1 then min(t.name)
                else (array_agg(t.name order by t.ord))[1] || ' +' || (count(*) - 1)
           end as occupant,
           nm.name as place
      from (select coalesce(
                     (select n.name from public.entity_names n
                       where n.entity_id = r.subject_id and n.valid @> p_at
                         and n.name_type in ('official', 'common', 'historic')
                       order by n.valid_from desc nulls last,
                                array_position(array['official', 'common', 'historic'], n.name_type)
                       limit 1),
                     so.name) as name,
                   row_number() over (order by r.valid_from desc nulls last, r.created_at) as ord
              from public.relations r
              join public.entities so on so.id = r.subject_id
             where r.object_id = e.id
               and r.predicate = 'occupies'
               and r.valid @> p_at) t
     where e.kind in ('building', 'site', 'parcel') and not f.ghost
  ) o on true
$$;

drop function if exists public.building_spaces(uuid, date);
create function public.building_spaces(p_building uuid, p_at date default current_date)
returns table (
  id uuid, slug text, name text, floor numeric, unit_label text, geojson jsonb,
  tenants text, present boolean,
  exists_from date, exists_from_precision public.date_precision,
  exists_to date, exists_to_precision public.date_precision,
  in_use boolean
)
language sql stable set search_path = public, extensions as $$
  select s.id, s.slug, public.name_at(s.id, p_at),
         (public.attribute_at(s.id, 'floor', p_at) #>> '{}')::numeric,
         public.attribute_at(s.id, 'unit_label', p_at) #>> '{}',
         st_asgeojson(public.geometry_at(s.id, p_at), 6)::jsonb,
         public.tenants_at(s.id, p_at),
         s.lifespan @> p_at,
         s.exists_from, s.exists_from_precision, s.exists_to, s.exists_to_precision,
         coalesce((select ls.is_extant and ls.decay_level = 0 and ls.id not in ('under_construction', 'proposed')
                     from public.lifecycle_statuses ls where ls.id = public.status_at(s.id, p_at)), false)
    from public.relations r
    join public.entities s on s.id = r.subject_id and s.kind = 'space'
   where r.object_id = p_building and r.predicate = 'part_of'
   order by 4 nulls first, 3
$$;
grant execute on function public.building_spaces(uuid, date) to anon, authenticated;
