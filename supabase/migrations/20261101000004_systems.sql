-- =============================================================================
-- Decaynet :: 0004 systems
--
-- "Systems" fold component facts into answers. They are pure, stable SQL
-- functions over the component tables, callable as Supabase RPCs:
--
--   name_at / status_at / address_at   scalar "as of" resolvers
--   map_snapshot(at, ...)              GeoJSON of everything standing on a date
--   moments_near(at, years)            events + photos around a date, located
--   entity_snapshot(id, at)            one entity folded to a single date
--   entity_timeline(id)                every fact about an entity, chronologically
--   entity_relations(id)               the full edge list, both directions
--   chronology(from, to)               city-wide "what happened" feed
--   search_entities(q)                 fuzzy search across every historic name
--
-- Resolution rule everywhere: a fact applies on date D when D falls inside its
-- precision-expanded window; if several overlap, the most recently started wins.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Unified fact view: all components behind one header
-- -----------------------------------------------------------------------------
create or replace view public.facts with (security_invoker = true) as
  select 'entity_names'::text as fact_table, f.id, f.entity_id, null::uuid as other_id,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Name: ' || f.name || ' (' || f.name_type || ')' as summary
    from public.entity_names f
  union all
  select 'entity_geometries', f.id, f.entity_id, null,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Geometry: ' || f.role || ' ' || replace(extensions.st_geometrytype(f.geom), 'ST_', '')
    from public.entity_geometries f
  union all
  select 'entity_states', f.id, f.entity_id, null,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Status: ' || f.status
    from public.entity_states f
  union all
  select 'entity_attributes', f.id, f.entity_id, null,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         f.key || ' = ' || (case when jsonb_typeof(f.value) = 'string' then f.value #>> '{}' else f.value::text end)
    from public.entity_attributes f
  union all
  select 'addresses', f.id, f.entity_id, f.street_id,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Address: ' || coalesce(f.house_number || ' ', '') || coalesce(f.raw_address, '(street)')
    from public.addresses f
  union all
  select 'relations', f.id, f.subject_id, f.object_id,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Relation: ' || f.predicate
    from public.relations f;

-- -----------------------------------------------------------------------------
-- Scalar resolvers
-- -----------------------------------------------------------------------------
create or replace function public.name_at(p_entity uuid, p_at date default current_date)
returns text language sql stable parallel safe set search_path = public as $$
  select coalesce(
    (select n.name from public.entity_names n
      where n.entity_id = p_entity and n.valid @> coalesce(p_at, current_date)
        and n.name_type in ('official', 'common', 'historic')
      order by n.valid_from desc nulls last,
               array_position(array['official', 'common', 'historic'], n.name_type)
      limit 1),
    (select e.name from public.entities e where e.id = p_entity)
  )
$$;

create or replace function public.status_at(p_entity uuid, p_at date default current_date)
returns text language sql stable parallel safe set search_path = public as $$
  select s.status from public.entity_states s
   where s.entity_id = p_entity and s.valid @> coalesce(p_at, current_date)
   order by s.valid_from desc nulls last
   limit 1
$$;

create or replace function public.address_at(p_entity uuid, p_at date default current_date)
returns text language sql stable parallel safe set search_path = public as $$
  select nullif(btrim(
           coalesce(a.house_number || ' ', '') ||
           coalesce(public.name_at(a.street_id, coalesce(p_at, current_date)), a.raw_address, '')
         ), '')
    from public.addresses a
   where a.entity_id = p_entity and a.valid @> coalesce(p_at, current_date)
   order by a.valid_from desc nulls last
   limit 1
$$;

-- Best geometry for an entity on a date (falls back to the latest known shape)
create or replace function public.geometry_at(p_entity uuid, p_at date default current_date)
returns extensions.geometry language sql stable parallel safe set search_path = public, extensions as $$
  select g.geom from public.entity_geometries g
   where g.entity_id = p_entity and g.role <> 'viewpoint'
   order by (g.valid @> coalesce(p_at, current_date)) desc, g.valid_from desc nulls last
   limit 1
$$;

-- Where did an event happen / where was a photo taken?
--   own geometry -> geometry of what it occurred_at / depicts, as of its start date
create or replace function public.locate(p_entity uuid)
returns extensions.geometry language sql stable parallel safe set search_path = public, extensions as $$
  select coalesce(
    (select g.geom from public.entity_geometries g
      where g.entity_id = p_entity
      order by (g.role = 'viewpoint') desc, g.valid_from desc nulls last limit 1),
    (select st_pointonsurface(public.geometry_at(r.object_id, coalesce(e.exists_from, current_date)))
       from public.relations r join public.entities e on e.id = p_entity
      where r.subject_id = p_entity and r.predicate in ('occurred_at', 'depicts', 'affected')
        and public.geometry_at(r.object_id, coalesce(e.exists_from, current_date)) is not null
      order by array_position(array['occurred_at', 'depicts', 'affected'], r.predicate)
      limit 1)
  )
$$;

-- -----------------------------------------------------------------------------
-- map_snapshot: the time machine
-- -----------------------------------------------------------------------------
create or replace function public.map_snapshot(
  p_at date default current_date,
  p_kinds text[] default null,
  p_west double precision default null,
  p_south double precision default null,
  p_east double precision default null,
  p_north double precision default null,
  p_ghosts boolean default true
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
    -- Things that are gone by p_at: drawn at their last known shape
    select distinct on (g.entity_id)
           g.entity_id, g.role, g.geom, g.confidence, true as ghost
      from public.entity_geometries g
      join public.entities e on e.id = g.entity_id
     cross join bbox
     where p_ghosts
       and g.role <> 'viewpoint'
       and e.kind in ('building', 'street', 'site', 'infrastructure', 'parcel')
       and (p_kinds is null or e.kind = any (p_kinds))
       and upper(e.lifespan) <= p_at
       and (bbox.env is null or g.geom && bbox.env)
     order by g.entity_id, g.valid_from desc nulls last
  ),
  feats as (select * from live union all select * from ghosts)
  select jsonb_build_object(
    'type', 'FeatureCollection',
    'at', p_at,
    'features', coalesce(jsonb_agg(jsonb_build_object(
      'type', 'Feature',
      'id', f.entity_id,
      'geometry', st_asgeojson(f.geom, 6)::jsonb,
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
      )
    ) order by k.sort desc), '[]'::jsonb)
  )
  from feats f
  join public.entities e on e.id = f.entity_id
  join public.entity_kinds k on k.id = e.kind
  left join public.lifecycle_statuses st on st.id = public.status_at(e.id, p_at)
$$;

-- -----------------------------------------------------------------------------
-- moments_near: events and dated media within +/- N years of a date
-- -----------------------------------------------------------------------------
create or replace function public.moments_near(
  p_at date default current_date,
  p_years integer default 5,
  p_limit integer default 400
) returns jsonb
language sql stable set search_path = public, extensions as $$
  with win as (
    select daterange((p_at - make_interval(years => p_years))::date,
                     (p_at + make_interval(years => p_years))::date, '[]') as r
  ),
  m as (
    select e.id, e.slug, e.kind, e.name, e.exists_from, e.exists_from_precision,
           e.exists_to, e.exists_to_precision,
           coalesce(ed.event_type, mi.media_type) as subtype,
           coalesce(et.color, case when e.kind = 'media' then '#8fb3c9' end, '#e0a23a') as color,
           public.locate(e.id) as geom,
           abs(lower(e.lifespan) - p_at) as distance_days
      from public.entities e
      cross join win
      left join public.event_details ed on ed.entity_id = e.id
      left join public.event_types et on et.id = ed.event_type
      left join public.media_items mi on mi.entity_id = e.id
     where e.kind in ('event', 'media')
       and e.exists_from is not null
       and e.lifespan && win.r
     order by distance_days
     limit p_limit
  )
  select jsonb_build_object(
    'type', 'FeatureCollection',
    'features', coalesce(jsonb_agg(jsonb_build_object(
      'type', 'Feature',
      'id', m.id,
      'geometry', st_asgeojson(st_pointonsurface(m.geom), 6)::jsonb,
      'properties', jsonb_build_object(
        'id', m.id, 'slug', m.slug, 'kind', m.kind, 'name', m.name,
        'subtype', m.subtype, 'color', m.color,
        'from', m.exists_from, 'from_precision', m.exists_from_precision,
        'to', m.exists_to, 'to_precision', m.exists_to_precision,
        'years_away', round(m.distance_days / 365.25, 1),
        'nearness', greatest(0.15, 1 - (m.distance_days / 365.25) / greatest(p_years, 1))
      )
    )) filter (where m.geom is not null), '[]'::jsonb),
    'unplaced', coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'slug', m.slug, 'kind', m.kind, 'name', m.name, 'subtype', m.subtype,
      'from', m.exists_from, 'from_precision', m.exists_from_precision
    )) filter (where m.geom is null), '[]'::jsonb)
  )
  from m
$$;

-- -----------------------------------------------------------------------------
-- entity_relations: full edge list, both directions, with period-correct names
-- -----------------------------------------------------------------------------
create or replace function public.entity_relations(p_entity uuid)
returns table (
  id uuid,
  direction text,
  predicate text,
  label text,
  other_id uuid,
  other_slug text,
  other_kind text,
  other_name text,
  other_name_then text,
  qualifiers jsonb,
  valid_from date,
  valid_from_precision public.date_precision,
  valid_to date,
  valid_to_precision public.date_precision,
  confidence public.confidence_level,
  source_id uuid,
  source_detail text,
  note text,
  sort smallint
)
language sql stable set search_path = public as $$
  select r.id, 'out', r.predicate, rt.label, o.id, o.slug, o.kind, o.name,
         public.name_at(o.id, coalesce(r.valid_from, o.exists_from, current_date)),
         r.qualifiers, r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision,
         r.confidence, r.source_id, r.source_detail, r.note, rt.sort
    from public.relations r
    join public.relation_types rt on rt.id = r.predicate
    join public.entities o on o.id = r.object_id
   where r.subject_id = p_entity
  union all
  select r.id, 'in', r.predicate, rt.inverse_label, s.id, s.slug, s.kind, s.name,
         public.name_at(s.id, coalesce(r.valid_from, s.exists_from, current_date)),
         r.qualifiers, r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision,
         r.confidence, r.source_id, r.source_detail, r.note, rt.sort
    from public.relations r
    join public.relation_types rt on rt.id = r.predicate
    join public.entities s on s.id = r.subject_id
   where r.object_id = p_entity
$$;

-- -----------------------------------------------------------------------------
-- entity_snapshot: one entity, folded to a single date
-- -----------------------------------------------------------------------------
create or replace function public.entity_snapshot(p_entity uuid, p_at date default current_date)
returns jsonb
language sql stable set search_path = public, extensions as $$
  select jsonb_build_object(
    'at', p_at,
    'id', e.id,
    'slug', e.slug,
    'kind', e.kind,
    'kind_label', k.label,
    'canonical_name', e.name,
    'name', public.name_at(e.id, p_at),
    'summary', e.summary,
    'exists_from', e.exists_from, 'exists_from_precision', e.exists_from_precision,
    'exists_to', e.exists_to, 'exists_to_precision', e.exists_to_precision,
    'phase', case
       when e.lifespan @> p_at then 'present'
       when not lower_inf(e.lifespan) and p_at < lower(e.lifespan) then 'future'
       else 'past' end,
    'status', (select jsonb_build_object('id', ls.id, 'label', ls.label, 'color', ls.color,
                                         'decay_level', ls.decay_level, 'is_extant', ls.is_extant)
                 from public.lifecycle_statuses ls where ls.id = public.status_at(e.id, p_at)),
    'address', public.address_at(e.id, p_at),
    'other_names', (select coalesce(jsonb_agg(jsonb_build_object(
                        'name', n.name, 'name_type', n.name_type,
                        'valid_from', n.valid_from, 'valid_from_precision', n.valid_from_precision,
                        'valid_to', n.valid_to, 'valid_to_precision', n.valid_to_precision,
                        'current', n.valid @> p_at) order by n.valid_from nulls first), '[]'::jsonb)
                      from public.entity_names n where n.entity_id = e.id),
    'attributes', (select coalesce(jsonb_agg(jsonb_build_object(
                        'key', a.key, 'label', ak.label, 'value', a.value, 'unit', ak.unit,
                        'value_type', ak.value_type) order by ak.sort, ak.label), '[]'::jsonb)
                     from (select distinct on (x.key) x.*
                             from public.entity_attributes x
                            where x.entity_id = e.id and x.valid @> p_at
                            order by x.key, x.valid_from desc nulls last) a
                     join public.attribute_keys ak on ak.id = a.key),
    'relations', (select coalesce(jsonb_agg(jsonb_build_object(
                        'direction', r.direction, 'predicate', r.predicate, 'label', r.label,
                        'id', r.other_id, 'slug', r.other_slug, 'kind', r.other_kind,
                        'name', public.name_at(r.other_id, p_at), 'qualifiers', r.qualifiers,
                        'valid_from', r.valid_from, 'valid_from_precision', r.valid_from_precision,
                        'valid_to', r.valid_to, 'valid_to_precision', r.valid_to_precision)
                        order by r.sort, r.label), '[]'::jsonb)
                    from public.entity_relations(e.id) r
                   where public.fuzzy_range(r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision) @> p_at
                     and r.other_kind <> 'media'),
    'media', (select coalesce(jsonb_agg(x.j order by x.d), '[]'::jsonb) from (
                select jsonb_build_object('id', me.id, 'slug', me.slug, 'name', me.name,
                         'media_type', mi.media_type, 'storage_path', mi.storage_path,
                         'external_url', mi.external_url, 'captured', me.exists_from,
                         'captured_precision', me.exists_from_precision) as j,
                       abs(coalesce(me.exists_from, current_date) - p_at) as d
                  from public.relations r
                  join public.entities me on me.id = r.subject_id
                  join public.media_items mi on mi.entity_id = me.id
                 where r.object_id = e.id and r.predicate = 'depicts'
                 order by d limit 8) x),
    'article', (select jsonb_build_object('status', a.status, 'status_label', s.label,
                         'status_color', s.color, 'word_count', a.word_count,
                         'excerpt', left(regexp_replace(
                           regexp_replace(a.body, '\[\[[a-z0-9-]+\|([^\]]+)\]\]|\[\[([a-z0-9-]+)\]\]', '\1\2', 'g'),
                           '[#*_>\[\]`]', '', 'g'), 420))
                  from public.articles a join public.article_statuses s on s.id = a.status
                 where a.entity_id = e.id),
    'location', (select st_asgeojson(st_pointonsurface(g), 6)::jsonb
                   from (select coalesce(public.geometry_at(e.id, p_at), public.locate(e.id)) as g) z
                  where g is not null)
  )
  from public.entities e
  join public.entity_kinds k on k.id = e.kind
  where e.id = p_entity
$$;

-- -----------------------------------------------------------------------------
-- entity_timeline: every fact about one entity, in order
-- -----------------------------------------------------------------------------
create or replace function public.entity_timeline(p_entity uuid)
returns table (
  at date,
  at_precision public.date_precision,
  until date,
  until_precision public.date_precision,
  category text,
  label text,
  ref_id uuid,
  ref_slug text,
  ref_kind text,
  ref_name text,
  fact_table text,
  fact_id uuid,
  confidence public.confidence_level,
  source_id uuid,
  color text
)
language sql stable set search_path = public, extensions as $$
  select * from (
    select e.exists_from, e.exists_from_precision, null::date, null::public.date_precision,
           'lifespan', k.start_verb, null::uuid, null, null, null,
           'entities', e.id, e.lifespan_confidence, null::uuid, '#7fae6a'
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.id = p_entity and e.exists_from is not null
    union all
    select e.exists_to, e.exists_to_precision, null, null,
           'lifespan', k.end_verb, null, null, null, null,
           'entities', e.id, e.lifespan_confidence, null, '#5b5150'
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.id = p_entity and e.exists_to is not null
    union all
    select n.valid_from, n.valid_from_precision, n.valid_to, n.valid_to_precision,
           'name', 'Known as “' || n.name || '”' ||
                   case when n.name_type <> 'official' then ' (' || n.name_type || ')' else '' end,
           null, null, null, null,
           'entity_names', n.id, n.confidence, n.source_id, '#d7c9a7'
      from public.entity_names n where n.entity_id = p_entity
    union all
    select s.valid_from, s.valid_from_precision, s.valid_to, s.valid_to_precision,
           'status', ls.label, null, null, null, null,
           'entity_states', s.id, s.confidence, s.source_id, ls.color
      from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
     where s.entity_id = p_entity
    union all
    select a.valid_from, a.valid_from_precision, a.valid_to, a.valid_to_precision,
           'address', 'Address: ' || coalesce(a.house_number || ' ', '') ||
                      coalesce(public.name_at(a.street_id, coalesce(a.valid_from, current_date)), a.raw_address, '?'),
           st.id, st.slug, st.kind, st.name,
           'addresses', a.id, a.confidence, a.source_id, '#b9a68a'
      from public.addresses a left join public.entities st on st.id = a.street_id
     where a.entity_id = p_entity
    union all
    select a.valid_from, a.valid_from_precision, a.valid_to, a.valid_to_precision,
           'attribute', ak.label || ': ' ||
                        (case when jsonb_typeof(a.value) = 'string' then a.value #>> '{}' else a.value::text end) ||
                        coalesce(' ' || ak.unit, ''),
           null, null, null, null,
           'entity_attributes', a.id, a.confidence, a.source_id, '#9c8f7a'
      from public.entity_attributes a join public.attribute_keys ak on ak.id = a.key
     where a.entity_id = p_entity
    union all
    select g.valid_from, g.valid_from_precision, g.valid_to, g.valid_to_precision,
           'geometry', initcap(g.role) || ' mapped (' ||
                       lower(replace(st_geometrytype(g.geom), 'ST_', '')) || ')',
           null, null, null, null,
           'entity_geometries', g.id, g.confidence, g.source_id, '#6f8fa6'
      from public.entity_geometries g where g.entity_id = p_entity
    union all
    -- Relations; edges to events are shown at the event's own date
    select coalesce(r.valid_from, case when r.other_kind = 'event' then oe.exists_from end),
           case when r.valid_from is null and r.other_kind = 'event' then oe.exists_from_precision
                else r.valid_from_precision end,
           coalesce(r.valid_to, case when r.other_kind = 'event' then oe.exists_to end),
           case when r.valid_to is null and r.other_kind = 'event' then oe.exists_to_precision
                else r.valid_to_precision end,
           case when r.other_kind = 'event' then 'event'
                when r.other_kind = 'media' then 'media' else 'relation' end,
           case when r.other_kind = 'event' then coalesce(et.label, 'Event')
                else initcap(substr(r.label, 1, 1)) || substr(r.label, 2) end,
           r.other_id, r.other_slug, r.other_kind, r.other_name_then,
           'relations', r.id, r.confidence, r.source_id,
           coalesce(et.color, case when r.other_kind = 'media' then '#8fb3c9' else '#c2562b' end)
      from (
        -- an event linked several ways (occurred_at + affected) appears once
        select distinct on (case when x.other_kind = 'event' then x.other_id else x.id end) x.*
          from public.entity_relations(p_entity) x
         order by case when x.other_kind = 'event' then x.other_id else x.id end, x.sort
      ) r
      join public.entities oe on oe.id = r.other_id
      left join public.event_details ed on ed.entity_id = r.other_id
      left join public.event_types et on et.id = ed.event_type
  ) t (at, at_precision, until, until_precision, category, label, ref_id, ref_slug, ref_kind,
       ref_name, fact_table, fact_id, confidence, source_id, color)
  order by t.at nulls last, array_position(
    array['lifespan', 'name', 'address', 'status', 'event', 'relation', 'attribute', 'geometry', 'media'],
    t.category)
$$;

-- -----------------------------------------------------------------------------
-- chronology: what happened across the city in a window
-- -----------------------------------------------------------------------------
create or replace function public.chronology(
  p_from date default '1800-01-01',
  p_to date default current_date,
  p_kinds text[] default null,
  p_limit integer default 500
) returns table (
  at date,
  at_precision public.date_precision,
  until date,
  until_precision public.date_precision,
  category text,
  entity_id uuid,
  slug text,
  kind text,
  name text,
  label text,
  subtype text,
  color text
)
language sql stable set search_path = public as $$
  select * from (
    select e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision,
           'event', e.id, e.slug, e.kind, e.name, coalesce(et.label, 'Event'), ed.event_type,
           coalesce(et.color, '#e0a23a')
      from public.entities e
      left join public.event_details ed on ed.entity_id = e.id
      left join public.event_types et on et.id = ed.event_type
     where e.kind = 'event' and e.exists_from between p_from and p_to
    union all
    select e.exists_from, e.exists_from_precision, null, null,
           'start', e.id, e.slug, e.kind, public.name_at(e.id, e.exists_from), k.start_verb, null, '#7fae6a'
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.kind not in ('event', 'media') and e.exists_from between p_from and p_to
    union all
    select e.exists_to, e.exists_to_precision, null, null,
           'end', e.id, e.slug, e.kind, public.name_at(e.id, e.exists_to - 1), k.end_verb, null, '#5b5150'
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.kind not in ('event', 'media') and e.exists_to between p_from and p_to
    union all
    select s.valid_from, s.valid_from_precision, s.valid_to, s.valid_to_precision,
           'status', e.id, e.slug, e.kind, public.name_at(e.id, s.valid_from), ls.label, s.status, ls.color
      from public.entity_states s
      join public.entities e on e.id = s.entity_id
      join public.lifecycle_statuses ls on ls.id = s.status
     where ls.decay_level >= 2 and s.valid_from between p_from and p_to
  ) c (at, at_precision, until, until_precision, category, entity_id, slug, kind, name, label, subtype, color)
  where p_kinds is null or c.kind = any (p_kinds)
  order by c.at, c.name
  limit p_limit
$$;

-- -----------------------------------------------------------------------------
-- Search across canonical + historic names
-- -----------------------------------------------------------------------------
create or replace function public.search_entities(
  p_q text,
  p_kinds text[] default null,
  p_limit integer default 20
) returns table (
  id uuid, slug text, kind text, name text, matched_name text,
  exists_from date, exists_to date, score real
)
language sql stable set search_path = public, extensions as $$
  with q as (select btrim(p_q) as q),
  hits as (
    select e.id, e.name as matched, similarity(e.name, q.q) + case when e.name ilike q.q || '%' then 1 else 0 end as score
      from public.entities e, q
     where e.name ilike '%' || q.q || '%' or e.name % q.q or e.slug = lower(q.q)
    union all
    select n.entity_id, n.name, similarity(n.name, q.q) + case when n.name ilike q.q || '%' then 0.9 else 0 end
      from public.entity_names n, q
     where n.name ilike '%' || q.q || '%' or n.name % q.q
  ),
  best as (
    select distinct on (h.id) h.id, h.matched, h.score from hits h order by h.id, h.score desc
  )
  select e.id, e.slug, e.kind, e.name, b.matched, e.exists_from, e.exists_to, b.score::real
    from best b join public.entities e on e.id = b.id
   where p_kinds is null or e.kind = any (p_kinds)
   order by b.score desc, e.name
   limit p_limit
$$;

-- -----------------------------------------------------------------------------
-- Year range for the time slider
-- -----------------------------------------------------------------------------
create or replace function public.timeline_extent()
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'min_year', coalesce(least(
        (select min(extract(year from exists_from))::int from public.entities where kind <> 'person'),
        (select min(extract(year from valid_from))::int from public.entity_geometries)), 1850),
    'max_year', extract(year from current_date)::int
  )
$$;

-- -----------------------------------------------------------------------------
-- Geometry I/O (GeoJSON in/out so clients never touch WKB)
-- -----------------------------------------------------------------------------
create or replace view public.entity_geometries_geojson with (security_invoker = true) as
  select g.id, g.entity_id, g.role, g.valid_from, g.valid_from_precision, g.valid_to,
         g.valid_to_precision, g.confidence, g.source_id, g.source_detail, g.note,
         g.created_at, extensions.st_asgeojson(g.geom, 6)::jsonb as geojson
    from public.entity_geometries g;

create or replace function public.add_geometry(
  p_entity uuid,
  p_geojson jsonb,
  p_role text default 'shape',
  p_valid_from date default null,
  p_valid_from_precision public.date_precision default 'year',
  p_valid_to date default null,
  p_valid_to_precision public.date_precision default 'year',
  p_confidence public.confidence_level default 'probable',
  p_source_id uuid default null,
  p_source_detail text default null,
  p_note text default null
) returns uuid
language sql security invoker set search_path = public, extensions as $$
  insert into public.entity_geometries (
    entity_id, role, geom, valid_from, valid_from_precision, valid_to, valid_to_precision,
    confidence, source_id, source_detail, note)
  values (
    p_entity, p_role, st_setsrid(st_geomfromgeojson(p_geojson::text), 4326),
    p_valid_from, p_valid_from_precision, p_valid_to, p_valid_to_precision,
    p_confidence, p_source_id, p_source_detail, p_note)
  returning id
$$;

-- -----------------------------------------------------------------------------
-- entity_cards: list/browse view with present-day condition folded in
-- -----------------------------------------------------------------------------
create or replace view public.entity_cards with (security_invoker = true) as
  select e.id, e.slug, e.kind, e.name, e.summary,
         e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision,
         e.created_at, e.updated_at,
         public.status_at(e.id, current_date) as current_status,
         a.status as article_status, a.word_count
    from public.entities e
    left join public.articles a on a.entity_id = e.id;

-- -----------------------------------------------------------------------------
-- entity_health: derived maintenance signals ("what does this article need?")
-- -----------------------------------------------------------------------------
create or replace view public.entity_health with (security_invoker = true) as
  with c as (
    select e.id,
           (select count(*) from public.entity_geometries g where g.entity_id = e.id) as geometry_count,
           (select count(*) from public.facts f where f.entity_id = e.id) as fact_count,
           (select count(*) from public.facts f where f.entity_id = e.id and f.source_id is not null) as sourced_fact_count,
           (select count(*) from public.relations r where r.subject_id = e.id or r.object_id = e.id) as relation_count,
           (select count(*) from public.relations r where r.object_id = e.id and r.predicate = 'depicts') as media_count,
           (select count(*) from public.entity_states s where s.entity_id = e.id) as state_count
      from public.entities e
  )
  select e.id, e.slug, e.kind, e.name, e.exists_from, e.exists_to,
         a.status as article_status, a.word_count, a.updated_at as article_updated_at,
         c.geometry_count, c.fact_count, c.sourced_fact_count, c.relation_count, c.media_count, c.state_count,
         array_remove(array[
           case when k.geometry_hint is not null and c.geometry_count = 0 then 'no_geometry' end,
           case when e.kind in ('event', 'media') and public.locate(e.id) is null then 'unlocated' end,
           case when e.exists_from is null then 'no_start_date' end,
           case when coalesce(a.word_count, 0) < 60 then 'thin_article' end,
           case when c.fact_count > 0 and c.sourced_fact_count = 0 then 'unsourced' end,
           case when e.kind in ('building', 'site') and c.state_count = 0 then 'no_lifecycle' end,
           case when e.kind in ('building', 'site', 'street', 'event') and c.media_count = 0 then 'no_media' end,
           case when c.relation_count = 0 then 'orphan' end
         ], null) as issues
    from public.entities e
    join c on c.id = e.id
    join public.entity_kinds k on k.id = e.kind
    left join public.articles a on a.entity_id = e.id;
