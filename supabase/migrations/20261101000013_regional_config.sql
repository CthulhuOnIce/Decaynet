-- =============================================================================
-- Decaynet :: 0013 region-agnostic configuration
--
-- Nothing about a particular city lives in the schema any more. A fresh
-- install starts neutral (world view, no region) and is configured in the app
-- (Admin → Site settings / Vocabulary). The Gary, Indiana demo is optional
-- seed data (supabase/seed.sql, or SEED=1 with the Docker migrate runner).
-- =============================================================================

alter table public.site_settings
  add column units text not null default 'metric' check (units in ('metric', 'imperial')),
  add column address_format text not null default 'number_street'
    check (address_format in ('number_street', 'street_number')),
  add column content_language text not null default 'en' check (content_language ~ '^[a-z]{2,3}(-[A-Za-z]{2,4})?$'),
  add column map_bounds double precision[4],       -- [west, south, east, north]; null = whole world
  add column setup_complete boolean not null default false;

-- Neutral defaults for new installs
alter table public.site_settings
  alter column tagline set default 'A city through time',
  alter column region_name set default '',
  alter column map_center_lon set default 0,
  alter column map_center_lat set default 20,
  alter column map_zoom set default 2,
  alter column default_year set default 1950,
  alter column min_year set default 1800,
  alter column tips_intro set default 'Know something about a building, business, person or event? Tell us. You don''t need an account, and an editor will check it before anything is published.';

-- If the settings row still carries the old Gary defaults and was never edited
-- by a person, reset it to neutral (the demo seed sets Gary values explicitly).
update public.site_settings
   set tagline = 'A city through time', region_name = '',
       map_center_lon = 0, map_center_lat = 20, map_zoom = 2,
       default_year = 1950, min_year = 1800
 where id and updated_by is null
   and tagline = 'Gary, Indiana through time' and region_name = 'Gary, Indiana';

-- Existing, already-configured sites don't need the setup prompt
update public.site_settings set setup_complete = true where id and updated_by is not null;

-- Region-specific era tags belong to the demo data, not the schema
delete from public.tags t
 where t.slug in ('company-town', 'boom-years', 'decline') and t.facet = 'era'
   and not exists (select 1 from public.entity_tags et where et.tag_id = t.id)
   and not exists (select 1 from public.tags c where c.parent_id = t.id);

-- -----------------------------------------------------------------------------
-- Addresses follow the site's format ("577 Main St" vs "Hauptstraße 5")
-- -----------------------------------------------------------------------------
create or replace function public.format_address(p_number text, p_street text)
returns text language sql stable set search_path = public as $$
  select nullif(btrim(case
    when (select address_format from public.site_settings where id) = 'street_number'
      then coalesce(p_street, '') || coalesce(' ' || p_number, '')
    else coalesce(p_number || ' ', '') || coalesce(p_street, '')
  end), '')
$$;

create or replace function public.address_at(p_entity uuid, p_at date default current_date)
returns text language sql stable parallel safe set search_path = public as $$
  select public.format_address(
           a.house_number,
           coalesce(public.name_at(a.street_id, coalesce(p_at, current_date)), a.raw_address))
    from public.addresses a
   where a.entity_id = p_entity and a.valid @> coalesce(p_at, current_date)
   order by a.valid_from desc nulls last
   limit 1
$$;

-- -----------------------------------------------------------------------------
-- moments_near gains an optional bounding box (needed for country- or
-- world-scale sites, where "everything within 5 years" is too much)
-- -----------------------------------------------------------------------------
drop function public.moments_near(date, integer, integer);

create or replace function public.moments_near(
  p_at date default current_date,
  p_years integer default 5,
  p_limit integer default 400,
  p_west double precision default null,
  p_south double precision default null,
  p_east double precision default null,
  p_north double precision default null
) returns jsonb
language sql stable set search_path = public, extensions as $$
  with win as (
    select daterange((p_at - make_interval(years => p_years))::date,
                     (p_at + make_interval(years => p_years))::date, '[]') as r
  ),
  env as (
    select case when p_west is null then null
                else st_makeenvelope(p_west, p_south, p_east, p_north, 4326) end as g
  ),
  m0 as (
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
  ),
  m as (
    select m0.* from m0 cross join env
     where env.g is null or m0.geom is null or m0.geom && env.g
     order by m0.distance_days
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

-- Timeline address lines use the same format
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
           'address', 'Address: ' || coalesce(public.format_address(a.house_number,
                      coalesce(public.name_at(a.street_id, coalesce(a.valid_from, current_date)), a.raw_address)), '?'),
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
-- apply_import: tolerate end-before-start in source data; give imported
-- events an event type (the guessed one if this site has it, else "other")
-- -----------------------------------------------------------------------------
create or replace function public.apply_import(p_plan jsonb)
returns jsonb
language plpgsql security invoker set search_path = public, extensions as $$
declare
  it jsonb; x jsonb; v_id uuid; v_slug text; v_src uuid;
  v_sources jsonb := '{}'::jsonb;
  v_created uuid[] := '{}'; v_merged uuid[] := '{}';
  v_batch uuid; v_media uuid; v_today text := to_char(current_date, 'YYYY-MM-DD');
  v_from date; v_to date; v_fp public.date_precision; v_tp public.date_precision;
  v_conf public.confidence_level;
begin
  if not public.has_permission('bulk_edit') then
    raise exception 'You need the bulk map tools permission' using errcode = '42501';
  end if;

  -- One citation per source per import
  if 'ohm' = any (select jsonb_array_elements_text(p_plan -> 'sources')) then
    insert into public.sources (title, kind, url, publisher, notes)
    values ('OpenHistoricalMap (retrieved ' || v_today || ')', 'website', 'https://www.openhistoricalmap.org',
            'OpenHistoricalMap contributors',
            'CC0. Imported via the Decaynet import page for bbox ' || coalesce(p_plan ->> 'bbox', '?') || '.')
    returning id into v_src;
    v_sources := v_sources || jsonb_build_object('ohm', v_src);
  end if;
  if 'wikidata' = any (select jsonb_array_elements_text(p_plan -> 'sources')) then
    insert into public.sources (title, kind, url, publisher, notes)
    values ('Wikidata (retrieved ' || v_today || ')', 'website', 'https://www.wikidata.org', 'Wikimedia Foundation',
            'CC0. Imported via the Decaynet import page for bbox ' || coalesce(p_plan ->> 'bbox', '?') || '.')
    returning id into v_src;
    v_sources := v_sources || jsonb_build_object('wikidata', v_src);
  end if;

  for it in select * from jsonb_array_elements(p_plan -> 'items') loop
    v_from := nullif(it ->> 'exists_from', '')::date;
    v_to := nullif(it ->> 'exists_to', '')::date;
    v_fp := coalesce(nullif(it ->> 'exists_from_precision', ''), 'year')::public.date_precision;
    v_tp := coalesce(nullif(it ->> 'exists_to_precision', ''), 'year')::public.date_precision;
    v_conf := coalesce(nullif(it ->> 'confidence', ''), 'probable')::public.confidence_level;
    -- contradictory source dates must not abort the whole import
    if v_to is not null and v_from is not null and v_to < v_from then
      v_to := null;
    end if;

    if it ->> 'action' = 'create' then
      v_slug := coalesce(nullif(trim(both '-' from regexp_replace(lower(it ->> 'name'), '[^a-z0-9]+', '-', 'g')), ''), it ->> 'kind');
      v_slug := left(v_slug, 70);
      if exists (select 1 from public.entities where slug = v_slug) then
        v_slug := v_slug || '-' || substr(md5(random()::text), 1, 5);
      end if;
      insert into public.entities (kind, slug, name, summary, exists_from, exists_from_precision,
                                   exists_to, exists_to_precision, lifespan_confidence)
      values (it ->> 'kind', v_slug, it ->> 'name', nullif(it ->> 'summary', ''), v_from, v_fp, v_to, v_tp, v_conf)
      returning id into v_id;
      v_created := v_created || v_id;
      if it ->> 'kind' = 'event' then
        insert into public.event_details (entity_id, event_type)
        values (v_id, coalesce((select id from public.event_types where id = it ->> 'event_type'), 'other'));
      end if;
    else
      v_id := (it ->> 'entity_id')::uuid;
      update public.entities
         set exists_from = coalesce(exists_from, v_from),
             exists_from_precision = case when exists_from is null and v_from is not null then v_fp else exists_from_precision end,
             exists_to = coalesce(exists_to, v_to),
             exists_to_precision = case when exists_to is null and v_to is not null then v_tp else exists_to_precision end,
             summary = coalesce(summary, nullif(it ->> 'summary', ''))
       where id = v_id;
      v_merged := v_merged || v_id;
    end if;

    -- Shape
    if it -> 'geometry' is not null and jsonb_typeof(it -> 'geometry') = 'object' then
      insert into public.entity_geometries (entity_id, role, geom, valid_from, valid_from_precision,
                                            valid_to, valid_to_precision, confidence, source_id, note)
      values (v_id, coalesce(it ->> 'role', 'shape'),
              st_force2d(st_setsrid(st_geomfromgeojson((it -> 'geometry')::text), 4326)),
              v_from, v_fp, v_to, v_tp, v_conf,
              (v_sources ->> coalesce(it ->> 'geometry_source', 'ohm'))::uuid,
              'Imported: ' || coalesce(it ->> 'geometry_ref', ''));
    end if;

    -- Names (skip ones already present)
    for x in select * from jsonb_array_elements(coalesce(it -> 'names', '[]'::jsonb)) loop
      -- skip names the page already has, including its own title
      if not exists (select 1 from public.entity_names n where n.entity_id = v_id and lower(n.name) = lower(x ->> 'name'))
         and not exists (select 1 from public.entities e where e.id = v_id and lower(e.name) = lower(x ->> 'name')) then
        insert into public.entity_names (entity_id, name, name_type, valid_from, valid_from_precision,
                                         valid_to, valid_to_precision, confidence, source_id)
        values (v_id, x ->> 'name', coalesce(x ->> 'name_type', 'alternate'),
                case when x ->> 'name_type' = 'official' then v_from end, v_fp,
                case when x ->> 'name_type' = 'official' then v_to end, v_tp,
                v_conf, (v_sources ->> coalesce(x ->> 'source', it ->> 'fact_source', 'ohm'))::uuid);
      end if;
    end loop;

    -- Attributes (only keys not present)
    for x in select * from jsonb_array_elements(coalesce(it -> 'attributes', '[]'::jsonb)) loop
      if exists (select 1 from public.attribute_keys k where k.id = x ->> 'key')
         and not exists (select 1 from public.entity_attributes a where a.entity_id = v_id and a.key = x ->> 'key') then
        insert into public.entity_attributes (entity_id, key, value, confidence, source_id)
        values (v_id, x ->> 'key', x -> 'value', v_conf,
                (v_sources ->> coalesce(x ->> 'source', it ->> 'fact_source', 'ohm'))::uuid);
      end if;
    end loop;

    -- Condition (only if the page has none)
    if nullif(it ->> 'status', '') is not null
       and not exists (select 1 from public.entity_states s where s.entity_id = v_id) then
      insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, confidence, source_id)
      values (v_id, it ->> 'status', coalesce(v_to, v_from), case when v_to is not null then v_tp else v_fp end, v_conf,
              (v_sources ->> coalesce(it ->> 'fact_source', 'ohm'))::uuid);
    end if;

    -- Tags (by slug, only existing tags, only if not present)
    insert into public.entity_tags (entity_id, tag_id, confidence, source_id)
    select v_id, t.id, 'probable', (v_sources ->> coalesce(it ->> 'fact_source', 'ohm'))::uuid
      from public.tags t
     where t.slug in (select jsonb_array_elements_text(coalesce(it -> 'tags', '[]'::jsonb)))
       and not exists (select 1 from public.entity_tags et where et.entity_id = v_id and et.tag_id = t.id);

    -- External ids
    insert into public.entity_external_ids (source, external_id, entity_id, url)
    select e ->> 'source', e ->> 'id', v_id, e ->> 'url'
      from jsonb_array_elements(coalesce(it -> 'ext', '[]'::jsonb)) e
    on conflict (source, external_id) do nothing;

    -- Optional linked image (Wikimedia Commons), as a media page that depicts this one
    if nullif(it ->> 'image_url', '') is not null then
      insert into public.entities (kind, slug, name, summary, lifespan_confidence)
      values ('media', left('image-' || coalesce(v_slug, (select slug from public.entities where id = v_id)), 60)
                       || '-' || substr(md5(random()::text), 1, 5),
              coalesce(it ->> 'name', (select name from public.entities where id = v_id)) || ' (Wikimedia Commons)',
              'Linked from Wikidata. See Wikimedia Commons for author and license.', 'speculative')
      returning id into v_media;
      insert into public.media_items (entity_id, media_type, external_url, rights, source_id)
      values (v_media, 'photo', it ->> 'image_url', 'See Wikimedia Commons file page for license',
              (v_sources ->> 'wikidata')::uuid);
      insert into public.relations (subject_id, predicate, object_id, confidence, source_id)
      values (v_media, 'depicts', v_id, 'speculative', (v_sources ->> 'wikidata')::uuid);
      v_created := v_created || v_media;
    end if;
    v_slug := null;
  end loop;

  insert into public.import_batches (sources, bbox, summary, created_entity_ids, merged_entity_ids)
  values (array(select jsonb_array_elements_text(p_plan -> 'sources')),
          case when jsonb_typeof(p_plan -> 'bbox') = 'array'
               then array(select jsonb_array_elements_text(p_plan -> 'bbox'))::float8[] end,
          jsonb_build_object('created', cardinality(v_created), 'merged', cardinality(v_merged),
                             'source_ids', v_sources),
          v_created, v_merged)
  returning id into v_batch;

  return jsonb_build_object('batch_id', v_batch, 'created', cardinality(v_created), 'merged', cardinality(v_merged));
end;
$$;
