-- =============================================================================
-- Decaynet :: 0042 move, name and redraw from the workbench selection
--
-- * move_shapes: shift (and turn) the shapes the map shows for the selected
--   pages in place, e.g. a building traced from a sanborn sheet that was
--   aligned a little off. No new version is made: the shape was always there.
--   Their interior spaces move with them.
-- * name_pages: "Named from 1925": an official name from then on, closing the
--   one running then, up to the next recorded name.
-- * redraw_shape: a new shape from a year (a renovation, or a better map): the
--   shape shown then ends at that year and the new one takes over until the
--   old one's end.
-- =============================================================================

/** The shapes the map shows for a page in a year: its shapes then, or, once it is gone, its last one. */
create or replace function public.shapes_shown(p_entity uuid, p_at date)
returns setof uuid
language sql stable security invoker set search_path = public as $$
  select g.id from public.entity_geometries g join public.entities e on e.id = g.entity_id
   where g.entity_id = p_entity and g.role <> 'viewpoint' and e.lifespan @> p_at and g.valid @> p_at
  union
  select * from (
    select g.id from public.entity_geometries g join public.entities e on e.id = g.entity_id
     where g.entity_id = p_entity and g.role <> 'viewpoint' and upper(e.lifespan) <= p_at
     order by g.valid_from desc nulls last
     limit 1) last_one
$$;
grant execute on function public.shapes_shown(uuid, date) to anon, authenticated;

/** Move the shapes shown in a year for these pages (and their interior spaces): turned by
 *  p_angle degrees counter-clockwise about the "from" point, then moved so it lands on "to".
 *  Worked out in web mercator, as the map draws it, so what was previewed is what's saved. */
create or replace function public.move_shapes(
  p_ids uuid[], p_at date,
  p_from_lon double precision, p_from_lat double precision,
  p_to_lon double precision, p_to_lat double precision,
  p_angle double precision default 0,
  p_spaces boolean default true
) returns jsonb
language plpgsql security invoker set search_path = public, extensions as $$
declare
  o geometry := st_transform(st_setsrid(st_makepoint(p_from_lon, p_from_lat), 4326), 3857);
  t geometry := st_transform(st_setsrid(st_makepoint(p_to_lon, p_to_lat), 4326), 3857);
  v_far double precision := st_distance(st_setsrid(st_makepoint(p_from_lon, p_from_lat), 4326)::geography,
                                         st_setsrid(st_makepoint(p_to_lon, p_to_lat), 4326)::geography);
  v_shapes int;
  v_pages int;
  v_spaces int;
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  if p_at is null then
    raise exception 'Which year''s shapes?' using errcode = '22023';
  end if;
  if v_far > 1500 then
    raise exception 'That moves them % m: more than a misaligned map would. Nothing was moved.', round(v_far::numeric) using errcode = '22023';
  end if;

  with moving as (
    -- a space that was selected too moves once (as a page)
    select distinct on (g) g as geom_id, p.id as entity_id, p.is_space
      from (select e.id, false as is_space from public.entities e where e.id = any (p_ids)
            union
            select s.id, true from unnest(p_ids) i cross join lateral public.interior_spaces(i) s where p_spaces) p
     cross join lateral public.shapes_shown(p.id, p_at) g
     order by g, p.is_space
  ), moved as (
    update public.entity_geometries x
       set geom = st_transform(st_translate(st_rotate(st_transform(x.geom, 3857), radians(p_angle), o),
                                            st_x(t) - st_x(o), st_y(t) - st_y(o)), 4326)
      from moving m where m.geom_id = x.id
    returning m.entity_id, m.is_space
  )
  select count(*), count(distinct entity_id) filter (where not is_space), count(distinct entity_id) filter (where is_space)
    into v_shapes, v_pages, v_spaces from moved;
  return jsonb_build_object('shapes', v_shapes, 'pages', v_pages, 'spaces', v_spaces);
end;
$$;
grant execute on function public.move_shapes(uuid[], date, double precision, double precision, double precision, double precision, double precision, boolean) to authenticated;

/** An official name from a date on: the name running then ends there; the new one runs up to the next. */
create or replace function public.name_pages(
  p_ids uuid[], p_at date, p_name text,
  p_precision public.date_precision default 'year',
  p_note text default null
) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  e record;
  cur record;
  nxt record;
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_done int := 0;
  v_skipped jsonb := '[]';
  v_when text := public.fuzzy_label(p_at, p_precision);
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  if p_at is null then
    raise exception 'From which year?' using errcode = '22023';
  end if;
  if v_name = '' then
    raise exception 'What was it called?' using errcode = '22023';
  end if;

  for e in select * from public.entities where id = any (p_ids) order by name loop
    if e.exists_to is not null and p_at >= public.precision_end(e.exists_to, e.exists_to_precision) then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'gone by ' || v_when || ' (' || public.fuzzy_label(e.exists_to, e.exists_to_precision) || ')');
      continue;
    end if;
    if e.exists_from is not null and public.precision_end(p_at, p_precision) <= e.exists_from then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'not there yet in ' || v_when || ' (starts ' || public.fuzzy_label(e.exists_from, e.exists_from_precision) || '): mark it “still standing in” first');
      continue;
    end if;

    -- the official name running then (the latest to start, if dated names overlap)
    select * into cur from public.entity_names n
     where n.entity_id = e.id and n.name_type = 'official' and n.valid @> p_at
     order by n.valid_from desc nulls last limit 1;
    if found and cur.name = v_name then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'reason', 'already called that in ' || v_when);
      continue;
    end if;
    if found and cur.valid_from is not null and cur.valid_from >= p_at then
      -- a name that starts then: it's this one, spelled differently
      update public.entity_names set name = v_name, note = coalesce(p_note, note) where id = cur.id;
      v_done := v_done + 1;
      continue;
    end if;

    if found then
      update public.entity_names set valid_to = p_at, valid_to_precision = p_precision where id = cur.id;
      insert into public.entity_names (entity_id, name, name_type, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, note)
      values (e.id, v_name, 'official', p_at, p_precision, cur.valid_to, cur.valid_to_precision, 'approximate', p_note);
    else
      -- up to the next recorded name, if there is one
      select * into nxt from public.entity_names n
       where n.entity_id = e.id and n.name_type = 'official' and n.valid_from > p_at
       order by n.valid_from limit 1;
      insert into public.entity_names (entity_id, name, name_type, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, note)
      values (e.id, v_name, 'official', p_at, p_precision,
              case when nxt.id is not null then nxt.valid_from end, coalesce(nxt.valid_from_precision, 'year'), 'approximate', p_note);
    end if;
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('done', v_done, 'skipped', v_skipped);
end;
$$;
grant execute on function public.name_pages(uuid[], date, text, public.date_precision, text) to authenticated;

/** A new shape for a page from a date: the shape shown then ends there and this one takes
 *  over up to its old end. A shape that starts then anyway is redrawn in place. */
create or replace function public.redraw_shape(
  p_entity uuid, p_at date, p_geojson jsonb,
  p_precision public.date_precision default 'year',
  p_confidence public.confidence_level default 'probable',
  p_source_id uuid default null,
  p_note text default null
) returns jsonb
language plpgsql security invoker set search_path = public, extensions as $$
declare
  e record;
  old record;
  g geometry;
  v_new uuid;
  v_roles text[];
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  select * into e from public.entities where id = p_entity;
  if not found then
    raise exception 'Page not found' using errcode = 'P0002';
  end if;
  if p_at is null then
    raise exception 'From which year?' using errcode = '22023';
  end if;
  if e.exists_to is not null and p_at >= public.precision_end(e.exists_to, e.exists_to_precision) then
    raise exception '% is gone by % (%)', e.name, public.fuzzy_label(p_at, p_precision), public.fuzzy_label(e.exists_to, e.exists_to_precision) using errcode = '22023';
  end if;
  begin
    g := st_setsrid(st_geomfromgeojson(p_geojson::text), 4326);
  exception when others then
    raise exception 'That shape isn''t valid GeoJSON' using errcode = '22023';
  end;
  -- the old shape it replaces: same kind of shape (outline, line or point)
  v_roles := case when geometrytype(g) in ('POLYGON', 'MULTIPOLYGON') then array['footprint', 'shape', 'boundary']
                  when geometrytype(g) in ('LINESTRING', 'MULTILINESTRING') then array['centerline', 'shape']
                  else array['point', 'shape'] end;
  select * into old from public.entity_geometries x
   where x.entity_id = p_entity and x.role = any (v_roles) and x.valid @> p_at
   order by array_position(v_roles, x.role), x.valid_from desc nulls last limit 1;

  if not found then
    insert into public.entity_geometries (entity_id, role, geom, valid_from, valid_from_precision, confidence, source_id, note)
    values (p_entity, v_roles[1], g, p_at, p_precision, p_confidence, p_source_id, p_note)
    returning id into v_new;
    return jsonb_build_object('id', v_new, 'ended', null, 'replaced', false);
  end if;
  if old.valid_from is not null and old.valid_from >= p_at then
    update public.entity_geometries set geom = g, confidence = p_confidence, source_id = coalesce(p_source_id, source_id), note = coalesce(p_note, note)
     where id = old.id;
    return jsonb_build_object('id', old.id, 'ended', null, 'replaced', true);
  end if;
  update public.entity_geometries set valid_to = p_at, valid_to_precision = p_precision where id = old.id;
  insert into public.entity_geometries (entity_id, role, geom, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, note)
  values (p_entity, old.role, g, p_at, p_precision, old.valid_to, old.valid_to_precision, p_confidence, p_source_id, p_note)
  returning id into v_new;
  return jsonb_build_object('id', v_new, 'ended', old.id, 'replaced', false);
end;
$$;
grant execute on function public.redraw_shape(uuid, date, jsonb, public.date_precision, public.confidence_level, uuid, text) to authenticated;
