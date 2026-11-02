-- =============================================================================
-- Decaynet :: 0017 more import sources
--
-- Adds OpenStreetMap (current), Wikipedia, Wikimedia Commons and GeoNames to
-- the importer:
--   * entity_external_ids accepts the new source ids
--   * apply_import cites each new source, can store a standalone Commons file
--     as a media page, and records a lifecycle status when a source gives one
-- =============================================================================

alter table public.entity_external_ids drop constraint if exists entity_external_ids_source_check;
alter table public.entity_external_ids
  add constraint entity_external_ids_source_check
  check (source in ('ohm', 'wikidata', 'osm', 'wikipedia', 'commons', 'geonames'));

create or replace function public.apply_import(p_plan jsonb)
returns jsonb
language plpgsql security invoker set search_path = public, extensions as $$
declare
  it jsonb; x jsonb; v_id uuid; v_slug text; v_src uuid; k text; m jsonb;
  v_sources jsonb := '{}'::jsonb;
  v_created uuid[] := '{}'; v_merged uuid[] := '{}';
  v_batch uuid; v_media uuid; v_today text := to_char(current_date, 'YYYY-MM-DD');
  v_from date; v_to date; v_fp public.date_precision; v_tp public.date_precision;
  v_conf public.confidence_level;
  -- title prefix, url, publisher, license note
  v_meta constant jsonb := jsonb_build_object(
    'ohm', jsonb_build_array('OpenHistoricalMap', 'https://www.openhistoricalmap.org', 'OpenHistoricalMap contributors', 'CC0.'),
    'osm', jsonb_build_array('OpenStreetMap', 'https://www.openstreetmap.org', 'OpenStreetMap contributors', 'ODbL 1.0, © OpenStreetMap contributors.'),
    'wikidata', jsonb_build_array('Wikidata', 'https://www.wikidata.org', 'Wikimedia Foundation', 'CC0.'),
    'wikipedia', jsonb_build_array('Wikipedia', 'https://www.wikipedia.org', 'Wikimedia Foundation', 'Text under CC BY-SA 4.0; see each article''s page history for authors.'),
    'commons', jsonb_build_array('Wikimedia Commons', 'https://commons.wikimedia.org', 'Wikimedia Foundation', 'Each file keeps its own license; see its Commons file page.'),
    'geonames', jsonb_build_array('GeoNames', 'https://www.geonames.org', 'GeoNames', 'CC BY 4.0.')
  );
begin
  if not public.has_permission('bulk_edit') then
    raise exception 'You need the bulk map tools permission' using errcode = '42501';
  end if;

  -- One citation per source per import
  for k in select jsonb_array_elements_text(p_plan -> 'sources') loop
    m := v_meta -> k;
    if m is null then continue; end if;
    insert into public.sources (title, kind, url, publisher, notes)
    values (m ->> 0 || ' (retrieved ' || v_today || ')', 'website', m ->> 1, m ->> 2,
            m ->> 3 || ' Imported via the Decaynet import page for bbox ' || coalesce(p_plan ->> 'bbox', '?') || '.')
    returning id into v_src;
    v_sources := v_sources || jsonb_build_object(k, v_src);
  end loop;

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
      -- A standalone file (Wikimedia Commons)
      if it ->> 'kind' = 'media' and jsonb_typeof(it -> 'media') = 'object' then
        insert into public.media_items (entity_id, media_type, external_url, mime_type, creator, rights, source_id)
        values (v_id, coalesce(nullif(it -> 'media' ->> 'media_type', ''), 'photo'), it -> 'media' ->> 'url',
                nullif(it -> 'media' ->> 'mime', ''), nullif(it -> 'media' ->> 'creator', ''),
                coalesce(nullif(it -> 'media' ->> 'rights', ''), 'See Wikimedia Commons file page for license'),
                (v_sources ->> coalesce(it ->> 'fact_source', 'commons'))::uuid);
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
      if exists (select 1 from public.attribute_keys k2 where k2.id = x ->> 'key')
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

-- -----------------------------------------------------------------------------
-- Import API credentials live in site secrets (editable at /admin/settings).
-- GeoNames needs a free account name; the GEONAMES_USERNAME env var is only a fallback.
-- -----------------------------------------------------------------------------
create or replace function public.set_site_secret(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_permission('manage_settings') then
    raise exception 'Only admins can change secrets' using errcode = '42501';
  end if;
  if p_key not in ('tips_captcha_secret', 'ip_hash_salt', 'geonames_username') then
    raise exception 'Unknown secret %', p_key using errcode = '22023';
  end if;
  if nullif(btrim(p_value), '') is null then
    delete from public.site_secrets where key = p_key;
  else
    insert into public.site_secrets (key, value, updated_at, updated_by)
    values (p_key, btrim(p_value), now(), auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  end if;
end;
$$;

create or replace function public.site_secret_status()
returns table (key text, is_set boolean, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select k.key, s.key is not null, s.updated_at
    from (values ('tips_captcha_secret'), ('ip_hash_salt'), ('geonames_username')) k (key)
    left join public.site_secrets s on s.key = k.key
   where public.has_permission('manage_settings')
$$;
