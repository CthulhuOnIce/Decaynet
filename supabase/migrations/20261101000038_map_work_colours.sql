-- =============================================================================
-- Decaynet :: 0038 map colours for work to do
--
-- * site_settings.unstated_color: buildings, sites and infrastructure that are
--   on the map but have no condition recorded for the date shown are drawn in
--   this colour (violet by default; empty = off), so the gaps stand out.
-- * map_snapshot() features carry no_status, article_status and article_color,
--   so the map can be coloured by article status instead (Stub, Draft, Needs
--   sources, Good...).
-- =============================================================================

alter table public.site_settings
  add column if not exists unstated_color text default '#b86bd6'
  check (unstated_color is null or unstated_color ~ '^#[0-9a-fA-F]{6}$');

comment on column public.site_settings.unstated_color is
  'Map colour for plotted buildings with no condition for the date shown (null: off).';

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
           (select ss.unstated_color from public.site_settings ss) as color
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
