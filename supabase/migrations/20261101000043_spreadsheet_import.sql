-- =============================================================================
-- Decaynet :: 0043 spreadsheet import, and several spaces at once
--
-- * Spreadsheet import (Import → Spreadsheet): rows of a CSV, for instance
--   every business on a block in a city directory, become pages linked to the
--   buildings (or storefronts) they were in that year.
--     match_table_rows    the preview: an existing page with the same name, the
--                         place (a page named in the row, or the building with
--                         that address in that year), a space by its unit, tags
--     apply_table_import  writes the reviewed rows in one go, as an import
--                         batch: pages, other names, tags, facts, the dated
--                         links (cited), new map points for addresses that match
--                         no building, and addresses for rows left unplaced
--   undo_import now also removes what an import added to existing pages.
-- * add_spaces: several spaces in one go (a pasted GeoJSON with one polygon per
--   storefront), all or none.
-- =============================================================================

/** "W. 5th Avenue" and "West 5th Ave." compare equal. */
create or replace function public.normalize_street(p text) returns text
language sql immutable parallel safe set search_path = public as $$
  select btrim(regexp_replace(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
      regexp_replace(lower(coalesce(p, '')), '[^a-z0-9 ]+', ' ', 'g'),
      '\mstreet\M', 'st', 'g'), '\mavenue\M', 'ave', 'g'), '\mav\M', 'ave', 'g'), '\mboulevard\M', 'blvd', 'g'),
      '\mroad\M', 'rd', 'g'), '\mdrive\M', 'dr', 'g'), '\mplace\M', 'pl', 'g'), '\mcourt\M', 'ct', 'g'),
      '\mlane\M', 'ln', 'g'), '\mparkway\M', 'pkwy', 'g'), '\mnorth\M', 'n', 'g'), '\msouth\M', 's', 'g'),
      '\meast\M', 'e', 'g'), '\mwest\M', 'w', 'g'),
    '\s+', ' ', 'g'))
$$;

/** House number and street of a written address: "512 Broadway", "Broadway 512", "512-14 W. 5th Ave, Gary". */
create or replace function public.split_address(p text, out house_number text, out street text)
language plpgsql immutable set search_path = public as $$
declare t text := btrim(split_part(coalesce(p, ''), ',', 1));
begin
  house_number := substring(t from '^(\d+[A-Za-z]?(?:\s*[-–]\s*\d+[A-Za-z]?)?)\s+\S');
  if house_number is not null then
    street := btrim(regexp_replace(t, '^\d+[A-Za-z]?(\s*[-–]\s*\d+[A-Za-z]?)?\s+', ''));
  else
    house_number := substring(t from '\S\s+(\d+[A-Za-z]?)$');
    street := case when house_number is not null then btrim(regexp_replace(t, '\s+\d+[A-Za-z]?$', '')) end;
  end if;
  -- "512-14": the first number is the one on the door
  house_number := btrim(split_part(regexp_replace(house_number, '\s', '', 'g'), '-', 1));
end;
$$;

/** A street page by any of its names (renamed streets keep their old names). */
create or replace function public.find_street(p_name text) returns uuid
language sql stable security invoker set search_path = public as $$
  select s.id from public.entities s
   where s.kind = 'street' and public.normalize_street(p_name) <> ''
     and (public.normalize_street(s.name) = public.normalize_street(p_name)
          or exists (select 1 from public.entity_names n where n.entity_id = s.id
                      and public.normalize_street(n.name) = public.normalize_street(p_name)))
   order by s.created_at limit 1
$$;
grant execute on function public.normalize_street(text) to anon, authenticated;
grant execute on function public.split_address(text) to anon, authenticated;
grant execute on function public.find_street(text) to anon, authenticated;

/** The preview of a spreadsheet import. p_rows: [{i, name, kind, place?, address?, unit?, at?, tags?: [text]}].
 *  Per row: {i, same, similar, place, space, place_how, tags: {found, missing}}. */
create or replace function public.match_table_rows(p_rows jsonb) returns jsonb
language sql stable security invoker set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'i', r.i, 'same', same.j, 'similar', case when same.j is null then sim.j end,
           'place', coalesce(byplace.j, byaddr.j), 'place_how', case when byplace.j is not null then 'named' when byaddr.j is not null then byaddr.how end,
           'space', sp.j, 'tags', tg.j) order by r.i), '[]'::jsonb)
    from jsonb_to_recordset(p_rows) as r (i int, name text, kind text, place text, address text, unit text, at date, tags jsonb)
    cross join lateral public.split_address(r.address) ad
    -- a page of the same kind with that name (or that name among its other names)
    left join lateral (
      select jsonb_build_object('id', e.id, 'slug', e.slug, 'name', e.name) j from public.entities e
       where e.kind = r.kind and (lower(e.name) = lower(btrim(r.name))
             or exists (select 1 from public.entity_names n where n.entity_id = e.id and lower(n.name) = lower(btrim(r.name))))
       order by e.created_at limit 1) same on true
    left join lateral (
      select jsonb_build_object('id', e.id, 'slug', e.slug, 'name', e.name, 'score', round(similarity(e.name, r.name)::numeric, 2)) j
        from public.entities e
       where e.kind = r.kind and e.name % r.name and similarity(e.name, r.name) >= 0.5
       order by similarity(e.name, r.name) desc limit 1) sim on true
    -- the place named in the row: a slug, a /e/slug link, or a name
    left join lateral (
      select jsonb_build_object('id', e.id, 'slug', e.slug, 'name', e.name, 'kind', e.kind) j from public.entities e
       where nullif(btrim(r.place), '') is not null
         and e.kind in ('building', 'site', 'parcel', 'space')
         and (e.slug = regexp_replace(btrim(r.place), '^.*/e/([^/?#]+).*$', '\1')
              or lower(e.name) = lower(btrim(r.place))
              or similarity(e.name, r.place) >= 0.5)
       order by (e.slug = regexp_replace(btrim(r.place), '^.*/e/([^/?#]+).*$', '\1')) desc,
                (lower(e.name) = lower(btrim(r.place))) desc, similarity(e.name, r.place) desc
       limit 1) byplace on true
    -- or the building with that address, preferring one standing then with the address then
    left join lateral (
      select jsonb_build_object('id', e.id, 'slug', e.slug, 'name', e.name, 'kind', e.kind) j,
             case when (r.at is null or (a.valid @> r.at and e.lifespan @> r.at)) then 'address' else 'address, other years' end how
        from public.addresses a join public.entities e on e.id = a.entity_id
       where byplace.j is null and ad.house_number is not null
         and e.kind in ('building', 'site', 'parcel', 'space')
         and lower(btrim(a.house_number)) = lower(ad.house_number)
         and (exists (select 1 from (select s.name from public.entities s where s.id = a.street_id
                                      union all select n.name from public.entity_names n where n.entity_id = a.street_id) sn
                       where public.normalize_street(sn.name) = public.normalize_street(ad.street))
              or public.normalize_street((public.split_address(a.raw_address)).street) = public.normalize_street(ad.street))
       order by (r.at is null or (a.valid @> r.at and e.lifespan @> r.at)) desc, (e.kind = 'space') desc, e.created_at
       limit 1) byaddr on true
    -- a storefront or suite of that place by its unit
    left join lateral (
      select jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name) j
        from public.relations rl join public.entities s on s.id = rl.subject_id and s.kind = 'space'
       where nullif(btrim(r.unit), '') is not null
         and rl.predicate = 'part_of' and rl.object_id = (coalesce(byplace.j, byaddr.j) ->> 'id')::uuid
         and (lower(s.name) = lower(btrim(r.unit))
              or s.name ~* ('\m' || regexp_replace(btrim(r.unit), '([^[:alnum:]])', '\\\1', 'g') || '\M')
              or exists (select 1 from public.entity_attributes at where at.entity_id = s.id and at.key = 'unit_label'
                          and lower(at.value #>> '{}') = lower(btrim(r.unit))))
       order by (lower(s.name) = lower(btrim(r.unit))) desc limit 1) sp on true
    -- tags by label or slug
    left join lateral (
      select jsonb_build_object(
               'found', coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'label', t.label)) filter (where t.id is not null), '[]'),
               'missing', coalesce(jsonb_agg(x.v) filter (where t.id is null), '[]')) j
        from jsonb_array_elements_text(coalesce(r.tags, '[]')) x(v)
        left join lateral (
          select t.id, t.label from public.tags t
           where lower(t.label) = lower(btrim(x.v)) or t.slug = trim(both '-' from regexp_replace(lower(btrim(x.v)), '[^a-z0-9]+', '-', 'g'))
           order by (lower(t.label) = lower(btrim(x.v))) desc limit 1) t on true) tg on true
$$;
grant execute on function public.match_table_rows(jsonb) to authenticated;

/** Write reviewed spreadsheet rows. Each row:
 *  {name, kind, entity_id?, summary?, names?: [text], tag_ids?: [uuid], attributes?: [{key, value}],
 *   from?, from_p?, to?, to_p? (a new page's lifespan), place_id?, predicate?,
 *   at_from?, at_from_p?, at_to?, at_to_p? (when the link held), note?, address?, unit?,
 *   lat?, lon?, point? (no place: a new building point at lat/lon)}
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
begin
  if not (public.has_permission('edit_content') and public.has_permission('bulk_edit')) then
    raise exception 'You need the edit content and bulk map tools permissions' using errcode = '42501';
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

    -- the page: an existing one, or a new one
    v_id := nullif(r ->> 'entity_id', '')::uuid;
    if v_id is null then
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
    elsif not exists (select 1 from public.entities where id = v_id) then
      raise exception 'Row % (%): the page to add to wasn''t found', v_rows, v_name using errcode = 'P0002';
    end if;

    -- other names, tags and facts (what the page doesn't have yet)
    for n in select distinct btrim(regexp_replace(x.v, '\s+', ' ', 'g')) from jsonb_array_elements_text(coalesce(r -> 'names', '[]')) x(v) where btrim(x.v) <> '' loop
      if lower(n) <> lower(v_name) and not exists (select 1 from public.entity_names where entity_id = v_id and lower(name) = lower(n)) then
        insert into public.entity_names (entity_id, name, name_type, source_id, confidence) values (v_id, n, 'alternate', p_source, p_confidence)
        returning id into x;
        if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{entity_names}', (v_added -> 'entity_names') || to_jsonb(x)); end if;
      end if;
    end loop;
    for t in select (x.v)::uuid from jsonb_array_elements_text(coalesce(r -> 'tag_ids', '[]')) x(v) loop
      if not exists (select 1 from public.entity_tags where entity_id = v_id and tag_id = t) then
        insert into public.entity_tags (entity_id, tag_id, source_id, confidence) values (v_id, t, p_source, p_confidence) returning id into x;
        if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{entity_tags}', (v_added -> 'entity_tags') || to_jsonb(x)); end if;
      end if;
    end loop;
    for a in select * from jsonb_array_elements(coalesce(r -> 'attributes', '[]')) loop
      insert into public.entity_attributes (entity_id, key, value, valid_from, valid_from_precision, valid_to, valid_to_precision, source_id, confidence)
      values (v_id, a ->> 'key', a -> 'value', f_from, f_from_p, f_to, f_to_p, p_source, p_confidence) returning id into x;
      if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{entity_attributes}', (v_added -> 'entity_attributes') || to_jsonb(x)); end if;
    end loop;

    v_addr := nullif(btrim(r ->> 'address'), '');
    v_hn := (public.split_address(v_addr)).house_number;
    v_street := (public.split_address(v_addr)).street;
    v_place := nullif(r ->> 'place_id', '')::uuid;

    if v_spatial then
      -- a place itself: a point where the row says, its address, and a space is part of its building
      if (r ->> 'lat') is not null and (r ->> 'lon') is not null then
        insert into public.entity_geometries (entity_id, role, geom, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id)
        values (v_id, 'point', st_setsrid(st_makepoint((r ->> 'lon')::float8, (r ->> 'lat')::float8), 4326), f_from, f_from_p, f_to, f_to_p, 'approximate', p_source)
        returning id into x;
        if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{entity_geometries}', (v_added -> 'entity_geometries') || to_jsonb(x)); end if;
        v_npoints := v_npoints + 1;
      end if;
      if v_addr is not null then
        insert into public.addresses (entity_id, street_id, house_number, unit, raw_address, valid_from, valid_from_precision, valid_to, valid_to_precision, source_id, confidence)
        values (v_id, public.find_street(v_street), v_hn, nullif(btrim(r ->> 'unit'), ''), v_addr, f_from, f_from_p, f_to, f_to_p, p_source, p_confidence)
        returning id into x;
        if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{addresses}', (v_added -> 'addresses') || to_jsonb(x)); end if;
        v_naddr := v_naddr + 1;
      end if;
      if v_place is not null and v_kind = 'space' then
        insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, note)
        values (v_id, 'part_of', v_place, f_from, f_from_p, f_to, f_to_p, p_confidence, p_source, nullif(btrim(r ->> 'note'), ''))
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
        insert into public.entity_geometries (entity_id, role, geom, confidence, source_id, note)
        values (v_place, 'point', st_setsrid(st_makepoint((r ->> 'lon')::float8, (r ->> 'lat')::float8), 4326), 'approximate', p_source,
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
        insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, note)
        values (v_id, v_pred, v_place, f_from, f_from_p, f_to, f_to_p, p_confidence, p_source, nullif(btrim(r ->> 'note'), ''))
        returning id into x;
        v_added := jsonb_set(v_added, '{relations}', (v_added -> 'relations') || to_jsonb(x));
        v_linked := v_linked + 1;
      end if;
    elsif v_addr is not null then
      -- nowhere on the map yet: keep the address on the page (address search finds it; place it later)
      insert into public.addresses (entity_id, street_id, house_number, unit, raw_address, valid_from, valid_from_precision, valid_to, valid_to_precision, source_id, confidence, note)
      values (v_id, public.find_street(v_street), v_hn, nullif(btrim(r ->> 'unit'), ''), v_addr, f_from, f_from_p, f_to, f_to_p, p_source, p_confidence,
              nullif(btrim(r ->> 'note'), ''))
      returning id into x;
      if not (v_id = any (v_created)) then v_added := jsonb_set(v_added, '{addresses}', (v_added -> 'addresses') || to_jsonb(x)); end if;
      v_naddr := v_naddr + 1;
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
grant execute on function public.apply_table_import(jsonb, uuid, public.confidence_level, boolean, text) to authenticated;

/** Undo an import: the pages it created, and (spreadsheet imports) what it added to existing pages. */
create or replace function public.undo_import(p_batch uuid)
returns integer
language plpgsql security invoker set search_path = public as $$
declare
  v_ids uuid[];
  v_added jsonb;
  v_n integer;
  tbl text;
begin
  if not public.has_permission('moderate') then
    raise exception 'Only moderators can undo an import' using errcode = '42501';
  end if;
  select created_entity_ids, summary -> 'added' into v_ids, v_added from public.import_batches where id = p_batch and undone_at is null;
  if v_ids is null then
    raise exception 'Unknown or already undone import' using errcode = 'P0002';
  end if;
  if v_added is not null then
    foreach tbl in array array['relations', 'entity_names', 'entity_tags', 'entity_attributes', 'addresses', 'entity_geometries'] loop
      if jsonb_array_length(coalesce(v_added -> tbl, '[]')) > 0 then
        execute format('delete from public.%I where id = any ($1)', tbl)
          using array(select (x.v)::uuid from jsonb_array_elements_text(v_added -> tbl) x(v));
      end if;
    end loop;
  end if;
  delete from public.entities where id = any (v_ids);
  get diagnostics v_n = row_count;
  update public.import_batches set undone_at = now() where id = p_batch;
  return v_n;
end;
$$;

/** Several spaces in one building at once (one per polygon), all or none.
 *  p_spaces: [{name, geojson, floor?, unit_label?}]. Returns the new slugs. */
create or replace function public.add_spaces(
  p_building uuid,
  p_spaces jsonb,
  p_from date default null,
  p_from_precision public.date_precision default 'year',
  p_to date default null,
  p_to_precision public.date_precision default 'year'
) returns text[]
language plpgsql security invoker set search_path = public as $$
declare
  s jsonb;
  out text[] := '{}';
  i int := 0;
begin
  for s in select * from jsonb_array_elements(p_spaces) loop
    i := i + 1;
    begin
      out := out || public.add_space(p_building, s ->> 'name', s -> 'geojson', (s ->> 'floor')::numeric, s ->> 'unit_label',
                                      p_from, p_from_precision, p_to, p_to_precision);
    exception when others then
      raise exception 'Space % (“%”): %', i, s ->> 'name', sqlerrm using errcode = sqlstate;
    end;
  end loop;
  return out;
end;
$$;
grant execute on function public.add_spaces(uuid, jsonb, date, public.date_precision, date, public.date_precision) to authenticated;
