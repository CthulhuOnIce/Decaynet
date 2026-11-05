-- =============================================================================
-- Decaynet :: 0045 spreadsheet rows over time
--
-- apply_table_import (as in 0044), so a sheet with one row per directory year
-- (a business in 1925, 1930 and 1935) comes out right:
--   * rows with the same name and kind make one page, not one each; its
--     lifespan widens to every row's From / Until
--   * a fact already on the page for the same time isn't added again, nor an
--     unplaced row's address (importing the same sheet twice adds nothing twice)
-- =============================================================================

/** Write reviewed spreadsheet rows. Each row:
 *  {name, kind, entity_id?, summary?, names?: [text], tag_ids?: [uuid], attributes?: [{key, value}],
 *   from?, from_p?, to?, to_p? (a new page's lifespan), place_id?, predicate?,
 *   at_from?, at_from_p?, at_to?, at_to_p? (when the link held), note?, address?, unit?,
 *   lat?, lon?, point? (no place: a new building point at lat/lon), source_detail? (page, entry)}
 *  Returns {batch_id, created, linked, points, addresses}. */
create or replace function public.apply_table_import(
  p_rows jsonb,
  p_source uuid default null,
  p_confidence public.confidence_level default 'probable',
  p_private boolean default false,
  p_label text default null
) returns jsonb
language plpgsql security invoker set search_path = public, extensions as $$
declare
  r jsonb;
  v_kind text;
  v_spatial boolean;
  v_id uuid;
  v_place uuid;
  v_new uuid;
  v_slug text;
  v_name text;
  v_pred text;
  v_addr text;
  v_hn text;
  v_street text;
  v_created uuid[] := '{}';
  v_added jsonb := jsonb_build_object('relations', '[]'::jsonb, 'entity_names', '[]'::jsonb, 'entity_tags', '[]'::jsonb,
                                      'entity_attributes', '[]'::jsonb, 'addresses', '[]'::jsonb, 'entity_geometries', '[]'::jsonb);
  v_points jsonb := '{}';
  v_linked int := 0;
  v_npoints int := 0;
  v_naddr int := 0;
  v_rows int := 0;
  v_batch uuid;
  t uuid;
  a jsonb;
  n text;
  x uuid;
  f_from date; f_from_p public.date_precision; f_to date; f_to_p public.date_precision;
  v_detail text;
  v_made jsonb := '{}';
  v_key text;
begin
  if not (public.has_permission('edit_content') and public.has_permission('bulk_edit')) then
    raise exception 'You need the edit content and bulk map tools permissions' using errcode = '42501';
  end if;
  if p_source is null or not exists (select 1 from public.sources where id = p_source) then
    raise exception 'Pick the source the sheet was made from (the directory, census or map), so every fact it adds is cited' using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_rows := v_rows + 1;
    v_name := btrim(regexp_replace(coalesce(r ->> 'name', ''), '\s+', ' ', 'g'));
    v_kind := coalesce(nullif(r ->> 'kind', ''), 'organization');
    if v_name = '' then
      raise exception 'Row % has no name', v_rows using errcode = '22023';
    end if;
    if not exists (select 1 from public.entity_kinds k where k.id = v_kind) then
      raise exception 'Row % (%): unknown kind “%”', v_rows, v_name, v_kind using errcode = '22023';
    end if;
    v_spatial := v_kind not in ('organization', 'person', 'event', 'media');
    f_from := (r ->> 'at_from')::date; f_from_p := coalesce(r ->> 'at_from_p', 'year')::public.date_precision;
    f_to := (r ->> 'at_to')::date; f_to_p := coalesce(r ->> 'at_to_p', 'year')::public.date_precision;
    v_detail := nullif(btrim(r ->> 'source_detail'), '');

    -- the page: an existing one, or a new one
    v_id := nullif(r ->> 'entity_id', '')::uuid;
    -- the same name (and kind) on several rows of one sheet is one page: a business in
    -- several directories, a fact over the years
    v_key := v_kind || '|' || lower(v_name);
    if v_id is null and v_made ? v_key then
      v_id := (v_made ->> v_key)::uuid;
      update public.entities e
         set exists_from = case when (r ->> 'from') is not null and (e.exists_from is null or (r ->> 'from')::date < e.exists_from) then (r ->> 'from')::date else e.exists_from end,
             exists_from_precision = case when (r ->> 'from') is not null and (e.exists_from is null or (r ->> 'from')::date < e.exists_from) then coalesce(r ->> 'from_p', 'year')::public.date_precision else e.exists_from_precision end,
             exists_to = case when (r ->> 'to') is not null and (e.exists_to is null or (r ->> 'to')::date > e.exists_to) then (r ->> 'to')::date else e.exists_to end,
             exists_to_precision = case when (r ->> 'to') is not null and (e.exists_to is null or (r ->> 'to')::date > e.exists_to) then coalesce(r ->> 'to_p', 'year')::public.date_precision else e.exists_to_precision end,
             summary = coalesce(e.summary, nullif(btrim(r ->> 'summary'), ''))
       where e.id = v_id;
    elsif v_id is null then
      v_slug := coalesce(nullif(trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g')), ''), v_kind);
      if exists (select 1 from public.entities where slug = v_slug) then
        v_slug := v_slug || '-' || substr(md5(random()::text), 1, 4);
      end if;
      insert into public.entities (kind, slug, name, summary, exists_from, exists_from_precision, exists_to, exists_to_precision,
                                   lifespan_confidence, is_private)
      values (v_kind, v_slug, v_name, nullif(btrim(r ->> 'summary'), ''),
              (r ->> 'from')::date, coalesce(r ->> 'from_p', 'year')::public.date_precision,
              (r ->> 'to')::date, coalesce(r ->> 'to_p', 'year')::public.date_precision,
              p_confidence, p_private)
      returning id into v_id;
      v_created := v_created || v_id;
      v_made := v_made || jsonb_build_object(v_key, v_id);
    elsif not exists (select 1 from public.entities where id = v_id) then
      raise exception 'Row % (%): the page to add to wasn''t found', v_rows, v_name using errcode = 'P0002';
    end if;

    -- other names, tags and facts (what the page doesn't have yet)
    for n in select distinct btrim(regexp_replace(x.v, '\s+', ' ', 'g')) from jsonb_array_elements_text(coalesce(r -> 'names', '[]')) x(v) where btrim(x.v) <> '' loop
      if lower(n) <> lower(v_name) and not exists (select 1 from public.entity_names where entity_id = v_id and lower(name) = lower(n)) then
        insert into public.entity_names (entity_id, name, name_type, source_id, source_detail, confidence) values (v_id, n, 'alternate', p_source, v_detail, p_confidence)
        returning id into x;
        if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{entity_names}', (v_added -> 'entity_names') || to_jsonb(x)); end if;
      end if;
    end loop;
    for t in select (x.v)::uuid from jsonb_array_elements_text(coalesce(r -> 'tag_ids', '[]')) x(v) loop
      if not exists (select 1 from public.entity_tags where entity_id = v_id and tag_id = t) then
        insert into public.entity_tags (entity_id, tag_id, source_id, source_detail, confidence) values (v_id, t, p_source, v_detail, p_confidence) returning id into x;
        if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{entity_tags}', (v_added -> 'entity_tags') || to_jsonb(x)); end if;
      end if;
    end loop;
    for a in select * from jsonb_array_elements(coalesce(r -> 'attributes', '[]')) loop
      -- the same fact for the same time is there already (a sheet imported twice)
      continue when exists (select 1 from public.entity_attributes x where x.entity_id = v_id and x.key = a ->> 'key' and x.value = a -> 'value'
                             and x.valid_from is not distinct from f_from and x.valid_to is not distinct from f_to);
      insert into public.entity_attributes (entity_id, key, value, valid_from, valid_from_precision, valid_to, valid_to_precision, source_id, source_detail, confidence)
      values (v_id, a ->> 'key', a -> 'value', f_from, f_from_p, f_to, f_to_p, p_source, v_detail, p_confidence) returning id into x;
      if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{entity_attributes}', (v_added -> 'entity_attributes') || to_jsonb(x)); end if;
    end loop;

    v_addr := nullif(btrim(r ->> 'address'), '');
    v_hn := (public.split_address(v_addr)).house_number;
    v_street := (public.split_address(v_addr)).street;
    v_place := nullif(r ->> 'place_id', '')::uuid;

    if v_spatial then
      -- a place itself: a point where the row says, its address, and a space is part of its building
      if (r ->> 'lat') is not null and (r ->> 'lon') is not null then
        insert into public.entity_geometries (entity_id, role, geom, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail)
        values (v_id, 'point', st_setsrid(st_makepoint((r ->> 'lon')::float8, (r ->> 'lat')::float8), 4326), f_from, f_from_p, f_to, f_to_p, 'approximate', p_source, v_detail)
        returning id into x;
        if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{entity_geometries}', (v_added -> 'entity_geometries') || to_jsonb(x)); end if;
        v_npoints := v_npoints + 1;
      end if;
      if v_addr is not null then
        insert into public.addresses (entity_id, street_id, house_number, unit, raw_address, valid_from, valid_from_precision, valid_to, valid_to_precision, source_id, source_detail, confidence)
        values (v_id, public.find_street(v_street), v_hn, nullif(btrim(r ->> 'unit'), ''), v_addr, f_from, f_from_p, f_to, f_to_p, p_source, v_detail, p_confidence)
        returning id into x;
        if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{addresses}', (v_added -> 'addresses') || to_jsonb(x)); end if;
        v_naddr := v_naddr + 1;
      end if;
      if v_place is not null and v_kind = 'space' then
        insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail, note)
        values (v_id, 'part_of', v_place, f_from, f_from_p, f_to, f_to_p, p_confidence, p_source, v_detail, nullif(btrim(r ->> 'note'), ''))
        returning id into x;
        v_added := jsonb_set(v_added, '{relations}', (v_added -> 'relations') || to_jsonb(x));
        v_linked := v_linked + 1;
      end if;
      continue;
    end if;

    -- an organization or person: where it was
    if v_place is null and coalesce((r ->> 'point')::boolean, false) and (r ->> 'lat') is not null and (r ->> 'lon') is not null then
      -- the same address twice in one sheet is one building
      v_place := nullif(v_points ->> lower(coalesce(v_addr, (r ->> 'lat') || ',' || (r ->> 'lon'))), '')::uuid;
      if v_place is null then
        v_slug := coalesce(nullif(trim(both '-' from regexp_replace(lower(coalesce(v_addr, v_name || ' building')), '[^a-z0-9]+', '-', 'g')), ''), 'building');
        if exists (select 1 from public.entities where slug = v_slug) then
          v_slug := v_slug || '-' || substr(md5(random()::text), 1, 4);
        end if;
        insert into public.entities (kind, slug, name, lifespan_confidence, is_private)
        values ('building', v_slug, coalesce(v_addr, v_name || ' building'), 'speculative', p_private)
        returning id into v_place;
        v_created := v_created || v_place;
        insert into public.entity_geometries (entity_id, role, geom, confidence, source_id, source_detail, note)
        values (v_place, 'point', st_setsrid(st_makepoint((r ->> 'lon')::float8, (r ->> 'lat')::float8), 4326), 'approximate', p_source, v_detail,
                'Placed by a spreadsheet import; trace the footprint when you can.');
        if v_addr is not null then
          insert into public.addresses (entity_id, street_id, house_number, raw_address, source_id, confidence)
          values (v_place, public.find_street(v_street), v_hn, v_addr, p_source, p_confidence);
        end if;
        v_points := v_points || jsonb_build_object(lower(coalesce(v_addr, (r ->> 'lat') || ',' || (r ->> 'lon'))), v_place);
        v_npoints := v_npoints + 1;
      end if;
    end if;

    if v_place is not null then
      v_pred := coalesce(nullif(r ->> 'predicate', ''), 'occupies');
      if not exists (select 1 from public.relations where subject_id = v_id and predicate = v_pred and object_id = v_place
                      and valid_from is not distinct from f_from and valid_to is not distinct from f_to) then
        insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail, note)
        values (v_id, v_pred, v_place, f_from, f_from_p, f_to, f_to_p, p_confidence, p_source, v_detail, nullif(btrim(r ->> 'note'), ''))
        returning id into x;
        v_added := jsonb_set(v_added, '{relations}', (v_added -> 'relations') || to_jsonb(x));
        v_linked := v_linked + 1;
      end if;
    elsif v_addr is not null then
      -- nowhere on the map yet: keep the address on the page (address search finds it; place it later)
      if not exists (select 1 from public.addresses x where x.entity_id = v_id and lower(x.raw_address) = lower(v_addr)
                      and x.valid_from is not distinct from f_from and x.valid_to is not distinct from f_to) then
      insert into public.addresses (entity_id, street_id, house_number, unit, raw_address, valid_from, valid_from_precision, valid_to, valid_to_precision, source_id, source_detail, confidence, note)
      values (v_id, public.find_street(v_street), v_hn, nullif(btrim(r ->> 'unit'), ''), v_addr, f_from, f_from_p, f_to, f_to_p, p_source, v_detail, p_confidence,
              nullif(btrim(r ->> 'note'), ''))
      returning id into x;
      if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{addresses}', (v_added -> 'addresses') || to_jsonb(x)); end if;
      v_naddr := v_naddr + 1;
      end if;
    end if;
  end loop;

  insert into public.import_batches (sources, summary, created_entity_ids)
  values (array['spreadsheet'], jsonb_build_object('label', p_label, 'rows', v_rows, 'created', cardinality(v_created), 'merged', 0,
                                                   'linked', v_linked, 'points', v_npoints, 'addresses', v_naddr, 'added', v_added),
          v_created)
  returning id into v_batch;
  return jsonb_build_object('batch_id', v_batch, 'created', cardinality(v_created), 'linked', v_linked, 'points', v_npoints, 'addresses', v_naddr);
end;
$$;
