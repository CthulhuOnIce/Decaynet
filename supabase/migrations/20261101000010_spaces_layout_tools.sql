-- =============================================================================
-- Decaynet :: 0010 spaces, natural features, image overlays, area tools
--
-- * Buildings carry real polygon footprints. Inside them, "space" entities
--   (storefronts, suites, floors, auditoriums) have their own polygons, and
--   tenants occupy *spaces* over time. Building > space > tenant.
-- * "water" and "landform" kinds let the shoreline, rivers, dunes and fill
--   change shape over time, for when the land itself was different.
-- * Overlays can be a scanned image pinned by four corners (georeferenced in
--   the workbench), not only XYZ tiles.
-- * retire_area / import_features: bulk tools for when a whole region's
--   layout changes (a highway cuts through, a neighborhood is re-platted).
-- =============================================================================

insert into public.entity_kinds (id, label, plural, color, geometry_hint, start_verb, end_verb, sort, description) values
  ('water',    'Water',            'Water',            '#4f7fa3', 'polygon', 'Formed',      'Filled',   4, 'Lake, river, lagoon, wetland. Shorelines and channels change over time.'),
  ('landform', 'Land & terrain',   'Land & terrain',   '#a08a5f', 'polygon', 'Formed',      'Removed',  6, 'Dunes, landfill, slag fields, ridges: the ground itself.'),
  ('space',    'Space',            'Spaces',           '#d9a46b', 'polygon', 'Created',     'Removed', 65, 'A storefront, suite, floor or hall inside a building. Tenants occupy spaces.')
on conflict (id) do nothing;

update public.relation_types
   set object_kinds = array_append(object_kinds, 'space')
 where id in ('occupies', 'resides_at', 'owns') and not ('space' = any (object_kinds));

insert into public.attribute_keys (id, label, value_type, unit, applies_to, sort) values
  ('floor',      'Floor',      'number', null,   '{space}', 5),
  ('unit_label', 'Unit / suite','text',  null,   '{space}', 6),
  ('area_sqft',  'Floor area', 'number', 'sq ft','{space,building}', 15)
on conflict (id) do nothing;

-- -----------------------------------------------------------------------------
-- Tenancy
-- -----------------------------------------------------------------------------
create or replace function public.tenants_at(p_space uuid, p_at date default current_date)
returns text language sql stable set search_path = public as $$
  select string_agg(public.name_at(r.subject_id, p_at), ', ' order by r.valid_from nulls first)
    from public.relations r
   where r.object_id = p_space
     and r.predicate in ('occupies', 'resides_at')
     and r.valid @> coalesce(p_at, current_date)
$$;

create or replace function public.attribute_at(p_entity uuid, p_key text, p_at date default current_date)
returns jsonb language sql stable set search_path = public as $$
  select a.value from public.entity_attributes a
   where a.entity_id = p_entity and a.key = p_key and a.valid @> coalesce(p_at, current_date)
   order by a.valid_from desc nulls last limit 1
$$;

-- Spaces of a building with their shapes and tenants on a date
create or replace function public.building_spaces(p_building uuid, p_at date default current_date)
returns table (
  id uuid, slug text, name text, floor numeric, unit_label text, geojson jsonb,
  tenants text, present boolean,
  exists_from date, exists_from_precision public.date_precision,
  exists_to date, exists_to_precision public.date_precision
)
language sql stable set search_path = public, extensions as $$
  select s.id, s.slug, public.name_at(s.id, p_at),
         (public.attribute_at(s.id, 'floor', p_at) #>> '{}')::numeric,
         public.attribute_at(s.id, 'unit_label', p_at) #>> '{}',
         st_asgeojson(public.geometry_at(s.id, p_at), 6)::jsonb,
         public.tenants_at(s.id, p_at),
         s.lifespan @> p_at,
         s.exists_from, s.exists_from_precision, s.exists_to, s.exists_to_precision
    from public.relations r
    join public.entities s on s.id = r.subject_id and s.kind = 'space'
   where r.object_id = p_building and r.predicate = 'part_of'
   order by 4 nulls first, 3
$$;

-- Create a space inside a building, validating it sits within the footprint
create or replace function public.add_space(
  p_building uuid,
  p_name text,
  p_geojson jsonb,
  p_floor numeric default null,
  p_unit_label text default null,
  p_from date default null,
  p_from_precision public.date_precision default 'year',
  p_to date default null,
  p_to_precision public.date_precision default 'year',
  p_tolerance_m double precision default 2
) returns text
language plpgsql security invoker set search_path = public, extensions as $$
declare
  v_building public.entities;
  v_footprint geometry;
  v_geom geometry;
  v_slug text;
  v_id uuid;
  v_at date;
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need edit permission' using errcode = '42501';
  end if;
  select * into v_building from public.entities where id = p_building;
  if v_building.kind not in ('building', 'site') then
    raise exception 'Spaces can only be added to buildings or sites' using errcode = '22023';
  end if;

  v_at := coalesce(p_from, v_building.exists_from, current_date);
  select g.geom into v_footprint
    from public.entity_geometries g
   where g.entity_id = p_building
     and st_dimension(g.geom) = 2
   order by (g.valid @> v_at) desc, g.valid_from desc nulls last
   limit 1;
  if v_footprint is null then
    raise exception 'Trace the building footprint (a polygon) before adding spaces' using errcode = '22023';
  end if;

  v_geom := st_setsrid(st_geomfromgeojson(p_geojson::text), 4326);
  if st_dimension(v_geom) <> 2 then
    raise exception 'A space must be a polygon' using errcode = '22023';
  end if;
  if not st_coveredby(v_geom, st_buffer(v_footprint::geography, p_tolerance_m)::geometry) then
    raise exception 'That space extends outside the building footprint (by more than % m)', p_tolerance_m
      using errcode = '23514';
  end if;

  v_slug := v_building.slug || '-' || coalesce(nullif(trim(both '-' from regexp_replace(lower(p_name), '[^a-z0-9]+', '-', 'g')), ''), 'space');
  if exists (select 1 from public.entities where slug = v_slug) then
    v_slug := v_slug || '-' || substr(md5(random()::text), 1, 4);
  end if;

  insert into public.entities (kind, slug, name, exists_from, exists_from_precision, exists_to, exists_to_precision, lifespan_confidence)
  values ('space', v_slug, p_name, coalesce(p_from, v_building.exists_from),
          case when p_from is null then v_building.exists_from_precision else p_from_precision end,
          p_to, p_to_precision, 'approximate')
  returning id into v_id;

  insert into public.entity_geometries (entity_id, role, geom, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence)
  values (v_id, 'footprint', v_geom, p_from, p_from_precision, p_to, p_to_precision, 'approximate');

  insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision)
  values (v_id, 'part_of', p_building, p_from, p_from_precision, p_to, p_to_precision);

  if p_floor is not null then
    insert into public.entity_attributes (entity_id, key, value) values (v_id, 'floor', to_jsonb(p_floor));
  end if;
  if nullif(btrim(p_unit_label), '') is not null then
    insert into public.entity_attributes (entity_id, key, value) values (v_id, 'unit_label', to_jsonb(btrim(p_unit_label)));
  end if;
  return v_slug;
end;
$$;

-- -----------------------------------------------------------------------------
-- map_snapshot v3: spaces carry tenant + floor; water/landform can be ghosts
-- -----------------------------------------------------------------------------
drop function public.map_snapshot(date, text[], double precision, double precision, double precision, double precision, boolean, text);

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
      ) else '{}'::jsonb end
    ) order by k.sort), '[]'::jsonb)
  )
  from feats f
  join public.entities e on e.id = f.entity_id
  join public.entity_kinds k on k.id = e.kind
  left join public.lifecycle_statuses st on st.id = public.status_at(e.id, p_at)
$$;

-- -----------------------------------------------------------------------------
-- Image overlays pinned by four corners
-- -----------------------------------------------------------------------------
alter table public.map_layers
  add column kind text not null default 'xyz' check (kind in ('xyz', 'image')),
  add column image_path text,          -- object path in the "media" bucket
  add column corners jsonb,            -- [[lon,lat] top-left, top-right, bottom-right, bottom-left]
  add column notes text,
  add column updated_at timestamptz not null default now();
alter table public.map_layers alter column tile_url drop not null;
alter table public.map_layers add constraint map_layers_source_check check (
  (kind = 'xyz' and tile_url is not null)
  or (kind = 'image' and image_path is not null and jsonb_array_length(corners) = 4)
);
create trigger touch before update on public.map_layers for each row execute function internal.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Area tools for when a whole region's layout changes
-- -----------------------------------------------------------------------------

-- Everything standing inside an area on a date
create or replace function public.entities_in_area(
  p_area jsonb, p_at date, p_kinds text[] default null
) returns table (id uuid, slug text, kind text, name text, status text)
language sql stable set search_path = public, extensions as $$
  with area as (select st_setsrid(st_geomfromgeojson(p_area::text), 4326) as g)
  select distinct e.id, e.slug, e.kind, public.name_at(e.id, p_at), public.status_at(e.id, p_at)
    from public.entities e
    join public.entity_geometries eg on eg.entity_id = e.id and eg.role <> 'viewpoint' and eg.valid @> p_at
    cross join area
   where e.lifespan @> p_at
     and e.kind not in ('event', 'media', 'district')
     and (p_kinds is null or e.kind = any (p_kinds))
     and st_intersects(eg.geom, area.g)
$$;

-- End everything in an area at a date (highway clearance, urban renewal, re-platting)
create or replace function public.retire_area(
  p_area jsonb,
  p_at date,
  p_precision public.date_precision default 'year',
  p_kinds text[] default '{building,street,site,parcel,space}',
  p_status text default 'demolished',
  p_note text default null,
  p_source_id uuid default null,
  p_ids uuid[] default null          -- optional: only these (after reviewing the preview)
) returns integer
language plpgsql security invoker set search_path = public, extensions as $$
declare v_count integer := 0; r record;
begin
  if not public.has_permission('bulk_edit') then
    raise exception 'You need the bulk map tools permission' using errcode = '42501';
  end if;
  for r in select * from public.entities_in_area(p_area, p_at - 1, p_kinds)
            where p_ids is null or id = any (p_ids) loop
    update public.entities
       set exists_to = p_at, exists_to_precision = p_precision, lifespan_confidence = 'approximate'
     where id = r.id;
    -- close open condition rows, then record the ending condition
    update public.entity_states set valid_to = p_at, valid_to_precision = p_precision
     where entity_id = r.id and valid_to is null and (valid_from is null or valid_from <= p_at);
    insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, confidence, note, source_id)
    values (r.id,
            case when r.kind = 'street' and p_status = 'demolished' then 'vacated' else p_status end,
            p_at, p_precision, 'approximate', coalesce(p_note, 'Area retired in the workbench'), p_source_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Bulk import a GeoJSON FeatureCollection as new entities
create or replace function public.import_features(
  p_fc jsonb,
  p_kind text,
  p_name_prop text default 'name',
  p_from date default null,
  p_from_precision public.date_precision default 'year',
  p_to date default null,
  p_to_precision public.date_precision default 'year',
  p_from_prop text default null,      -- per-feature start year property, e.g. "built"
  p_to_prop text default null,        -- per-feature end year property, e.g. "demolished"
  p_status text default null,
  p_confidence public.confidence_level default 'approximate',
  p_source_id uuid default null,
  p_role text default 'shape'
) returns integer
language plpgsql security invoker set search_path = public, extensions as $$
declare
  f jsonb; v_name text; v_slug text; v_id uuid; v_count integer := 0;
  v_from date; v_to date; v_fp public.date_precision; v_tp public.date_precision;
begin
  if not public.has_permission('bulk_edit') then
    raise exception 'You need the bulk map tools permission' using errcode = '42501';
  end if;
  if p_fc ->> 'type' <> 'FeatureCollection' then
    raise exception 'Expected a GeoJSON FeatureCollection' using errcode = '22023';
  end if;
  for f in select * from jsonb_array_elements(p_fc -> 'features') loop
    continue when f -> 'geometry' is null or f -> 'geometry' = 'null'::jsonb;
    v_name := coalesce(nullif(btrim(f -> 'properties' ->> p_name_prop), ''), initcap(p_kind) || ' ' || (v_count + 1));
    v_slug := coalesce(nullif(trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g')), ''), p_kind)
              || '-' || substr(md5(random()::text), 1, 5);
    v_from := p_from; v_fp := p_from_precision; v_to := p_to; v_tp := p_to_precision;
    if p_from_prop is not null and (f -> 'properties' ->> p_from_prop) ~ '^\d{4}' then
      v_from := make_date(substr(f -> 'properties' ->> p_from_prop, 1, 4)::int, 1, 1); v_fp := 'year';
    end if;
    if p_to_prop is not null and (f -> 'properties' ->> p_to_prop) ~ '^\d{4}' then
      v_to := make_date(substr(f -> 'properties' ->> p_to_prop, 1, 4)::int, 1, 1); v_tp := 'year';
    end if;

    insert into public.entities (kind, slug, name, exists_from, exists_from_precision, exists_to, exists_to_precision, lifespan_confidence)
    values (p_kind, v_slug, v_name, v_from, v_fp, v_to, v_tp, p_confidence)
    returning id into v_id;

    insert into public.entity_geometries (entity_id, role, geom, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, note)
    values (v_id, p_role, st_force2d(st_setsrid(st_geomfromgeojson((f -> 'geometry')::text), 4326)),
            v_from, v_fp, v_to, v_tp, p_confidence, p_source_id, 'Imported from GeoJSON');

    if p_status is not null then
      insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id)
      values (v_id, p_status, v_from, v_fp, v_to, v_tp, p_confidence, p_source_id);
    end if;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
