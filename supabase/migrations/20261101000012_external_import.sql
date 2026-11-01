-- =============================================================================
-- Decaynet :: 0012 external sources (OpenHistoricalMap, Wikidata) import
--
-- Schema only: the data itself is fetched live by the /import page, previewed
-- by an editor, and applied through apply_import(). Nothing is bundled here.
--
--   entity_external_ids   which OHM element / Wikidata item a page came from
--   import_batches        one row per applied import (for audit and undo)
--   match_import_candidates(jsonb)   find existing pages for fetched features
--   apply_import(jsonb)               write an approved plan in one transaction
-- =============================================================================

create table public.entity_external_ids (
  source text not null check (source in ('ohm', 'wikidata', 'osm')),
  external_id text not null,          -- "way/123", "Q7126191"
  entity_id uuid not null references public.entities (id) on delete cascade,
  url text,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  primary key (source, external_id)
);
create index entity_external_ids_entity_idx on public.entity_external_ids (entity_id);

alter table public.entity_external_ids enable row level security;
create policy "read entity_external_ids" on public.entity_external_ids for select to anon, authenticated using (true);
create policy "editors write entity_external_ids" on public.entity_external_ids for insert to authenticated
  with check ((select public.has_permission('edit_content')));
create policy "moderators delete entity_external_ids" on public.entity_external_ids for delete to authenticated
  using ((select public.has_permission('moderate')));

create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  sources text[] not null,
  bbox double precision[4],
  summary jsonb not null default '{}'::jsonb,
  created_entity_ids uuid[] not null default '{}',
  merged_entity_ids uuid[] not null default '{}',
  undone_at timestamptz,
  created_by uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.import_batches enable row level security;
create policy "read import_batches" on public.import_batches for select to authenticated
  using ((select public.has_permission('bulk_edit')));
create policy "bulk editors write import_batches" on public.import_batches for insert to authenticated
  with check ((select public.has_permission('bulk_edit')));
create policy "bulk editors update import_batches" on public.import_batches for update to authenticated
  using ((select public.has_permission('bulk_edit'))) with check ((select public.has_permission('bulk_edit')));

-- Kinds that may describe the same real-world thing (a theatre is never a street)
create or replace function public.kinds_compatible(a text, b text)
returns boolean language sql immutable as $$
  select a = b
      or (a in ('building', 'site', 'parcel') and b in ('building', 'site', 'parcel'))
      or (a in ('street', 'infrastructure') and b in ('street', 'infrastructure'))
      or (a in ('water', 'landform') and b in ('water', 'landform'))
$$;

-- -----------------------------------------------------------------------------
-- Matching: for each fetched candidate, the best existing page (if any)
--   input:  [{key, name, kind, wikidata, ext:[{source,id}], lon, lat, geom}]
--   match order: external id → wikidata attribute → overlapping footprint
--                → similar name nearby
-- -----------------------------------------------------------------------------
create or replace function public.match_import_candidates(p_candidates jsonb)
returns jsonb
language plpgsql stable security invoker set search_path = public, extensions as $$
declare
  c jsonb;
  out jsonb := '{}'::jsonb;
  v_id uuid;
  v_reason text;
  v_pt geometry;
  v_geom geometry;
begin
  for c in select * from jsonb_array_elements(p_candidates) loop
    v_id := null; v_reason := null;
    v_pt := case when c ? 'lon' and (c ->> 'lon') is not null
                 then st_setsrid(st_makepoint((c ->> 'lon')::float8, (c ->> 'lat')::float8), 4326) end;
    v_geom := case when c -> 'geom' is not null and jsonb_typeof(c -> 'geom') = 'object'
                   then st_setsrid(st_geomfromgeojson((c -> 'geom')::text), 4326) end;

    -- 1. already imported from the same source element
    select x.entity_id, 'same ' || x.source || ' id' into v_id, v_reason
      from public.entity_external_ids x
      join jsonb_array_elements(coalesce(c -> 'ext', '[]'::jsonb)) e
        on x.source = e ->> 'source' and x.external_id = e ->> 'id'
     limit 1;

    -- 2. same Wikidata item recorded as an attribute
    if v_id is null and nullif(c ->> 'wikidata', '') is not null then
      select a.entity_id, 'same Wikidata item' into v_id, v_reason
        from public.entity_attributes a
       where a.key = 'wikidata' and a.value #>> '{}' = c ->> 'wikidata'
       limit 1;
    end if;

    -- 3. footprint overlap (buildings and sites)
    if v_id is null and v_geom is not null and st_dimension(v_geom) = 2
       and c ->> 'kind' in ('building', 'site', 'space') then
      select g.entity_id, 'overlaps existing footprint' into v_id, v_reason
        from public.entity_geometries g
        join public.entities e on e.id = g.entity_id and e.kind in ('building', 'site')
       where g.role <> 'viewpoint'
         and g.geom && v_geom
         and (case when st_dimension(g.geom) = 2
                   then st_area(st_intersection(g.geom, v_geom)) > 0.3 * least(st_area(g.geom), st_area(v_geom))
                   else st_intersects(g.geom, v_geom) end)
       limit 1;
    end if;

    -- 4. similar name close by (or exact name for streets/water anywhere)
    if v_id is null and nullif(c ->> 'name', '') is not null then
      select e.id,
             case when lower(e.name) = lower(c ->> 'name') then 'same name nearby' else 'similar name nearby' end
        into v_id, v_reason
        from public.entities e
        left join lateral (select public.geometry_at(e.id, null) as g) gg on true
       where public.kinds_compatible(c ->> 'kind', e.kind)
         and (similarity(e.name, c ->> 'name') > 0.55
              or exists (select 1 from public.entity_names n
                          where n.entity_id = e.id and similarity(n.name, c ->> 'name') > 0.55))
         and (
           c ->> 'kind' in ('street', 'water', 'district', 'infrastructure')
           or (v_pt is not null and gg.g is not null and st_dwithin(gg.g::geography, v_pt::geography, 150))
           or (v_geom is not null and gg.g is not null and st_dwithin(gg.g::geography, v_geom::geography, 60))
         )
       order by similarity(e.name, c ->> 'name') desc
       limit 1;
    end if;

    if v_id is not null then
      out := out || jsonb_build_object(c ->> 'key', (
        select jsonb_build_object(
          'entity_id', e.id, 'slug', e.slug, 'name', e.name, 'kind', e.kind, 'reason', v_reason,
          'exists_from', e.exists_from, 'exists_to', e.exists_to,
          'has_shape', exists (select 1 from public.entity_geometries g
                                where g.entity_id = e.id and st_dimension(g.geom) >= 1),
          'has_geometry', exists (select 1 from public.entity_geometries g where g.entity_id = e.id),
          'has_status', exists (select 1 from public.entity_states s where s.entity_id = e.id),
          'summary', e.summary,
          'names', coalesce((select jsonb_agg(lower(n.name)) from public.entity_names n where n.entity_id = e.id), '[]'::jsonb)
                   || jsonb_build_array(lower(e.name)),
          'attributes', coalesce((select jsonb_agg(distinct a.key) from public.entity_attributes a where a.entity_id = e.id), '[]'::jsonb),
          'tags', coalesce((select jsonb_agg(distinct t.slug) from public.entity_tags et join public.tags t on t.id = et.tag_id
                             where et.entity_id = e.id), '[]'::jsonb),
          'ext', coalesce((select jsonb_agg(x.source || ':' || x.external_id) from public.entity_external_ids x
                            where x.entity_id = e.id), '[]'::jsonb)
        ) from public.entities e where e.id = v_id));
    end if;
  end loop;
  return out;
end;
$$;

-- -----------------------------------------------------------------------------
-- Apply an approved plan. Creates pages, or fills gaps on existing pages
-- (never overwrites). Every fact is cited to an auto-created source row for
-- this import. Runs as the caller, so RLS applies throughout.
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

-- Undo: delete pages an import created (merged additions stay; see change log)
create or replace function public.undo_import(p_batch uuid)
returns integer
language plpgsql security invoker set search_path = public as $$
declare v_ids uuid[]; v_n integer;
begin
  if not public.has_permission('moderate') then
    raise exception 'Only moderators can undo an import' using errcode = '42501';
  end if;
  select created_entity_ids into v_ids from public.import_batches where id = p_batch and undone_at is null;
  if v_ids is null then
    raise exception 'Unknown or already undone import' using errcode = 'P0002';
  end if;
  delete from public.entities where id = any (v_ids);
  get diagnostics v_n = row_count;
  update public.import_batches set undone_at = now() where id = p_batch;
  return v_n;
end;
$$;
