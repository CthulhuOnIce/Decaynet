-- =============================================================================
-- Decaynet :: 0047 a space fits any of its building's footprints
--
-- add_space (0010) checked a new space against one footprint: the one standing
-- at the space's start, or, with no start given, the building's first. A
-- storefront in a wing added later was refused although it sat inside the
-- footprint drawn for that wing. Now every footprint the building has had is
-- tried, and the space is bound to the first (in time) that it fits:
--   * no From given: the space starts when that footprint does (a storefront in
--     the 1955 wing starts in 1955; one in the original block, with the building)
--   * no Until given: if a later footprint no longer holds it (a rebuild left it
--     out), the space ends with the last footprint that did
--   * a From given: it has to fit a footprint standing then; if it only fits
--     another one, the message says which, instead of saving dates the shapes
--     contradict
-- =============================================================================

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
  v_geom geometry;
  v_slug text;
  v_id uuid;
  v_n int;
  v_first record;
  v_last record;
  v_from date := p_from;
  v_from_p public.date_precision := p_from_precision;
  v_to date := p_to;
  v_to_p public.date_precision := p_to_precision;
  v_fits text;
  v_fp jsonb;
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need edit permission' using errcode = '42501';
  end if;
  select * into v_building from public.entities where id = p_building;
  if v_building.kind not in ('building', 'site') then
    raise exception 'Spaces can only be added to buildings or sites' using errcode = '22023';
  end if;

  v_geom := st_setsrid(st_geomfromgeojson(p_geojson::text), 4326);
  if st_dimension(v_geom) <> 2 then
    raise exception 'A space must be a polygon' using errcode = '22023';
  end if;

  -- every outline the building has had, oldest first, and whether the space sits inside each
  select coalesce(jsonb_agg(jsonb_build_object('n', n, 'valid_from', valid_from, 'valid_from_precision', valid_from_precision,
                                              'valid_to', valid_to, 'valid_to_precision', valid_to_precision, 'fits', fits) order by n), '[]')
    into v_fp
    from (select row_number() over (order by g.valid_from nulls first, g.created_at) as n, g.valid_from, g.valid_from_precision, g.valid_to, g.valid_to_precision,
                 st_coveredby(v_geom, st_buffer(g.geom::geography, p_tolerance_m)::geometry) as fits
            from public.entity_geometries g
           where g.entity_id = p_building and g.role <> 'viewpoint' and st_dimension(g.geom) = 2) x;
  v_n := jsonb_array_length(v_fp);
  if v_n = 0 then
    raise exception 'Trace the building footprint (a polygon) before adding spaces' using errcode = '22023';
  end if;
  if not exists (select 1 from jsonb_to_recordset(v_fp) as f (n int, valid_from date, valid_from_precision public.date_precision, valid_to date, valid_to_precision public.date_precision, fits boolean) where fits) then
    raise exception 'That space extends outside the building footprint% (by more than % m)',
      case when v_n > 1 then 's (all ' || v_n || ' of them)' else '' end, p_tolerance_m using errcode = '23514';
  end if;

  if p_from is not null then
    -- it has to fit what stood then
    if not exists (select 1 from jsonb_to_recordset(v_fp) as f (n int, valid_from date, valid_from_precision public.date_precision, valid_to date, valid_to_precision public.date_precision, fits boolean) where fits and public.fuzzy_range(valid_from, valid_from_precision, valid_to, valid_to_precision) @> p_from) then
      select string_agg(coalesce(public.fuzzy_label(valid_from, valid_from_precision), 'the start') || '–' || coalesce(public.fuzzy_label(valid_to, valid_to_precision), ''), ', ' order by n)
        into v_fits from jsonb_to_recordset(v_fp) as f (n int, valid_from date, valid_from_precision public.date_precision, valid_to date, valid_to_precision public.date_precision, fits boolean) where fits;
      raise exception 'That space fits the footprint of %, not the one standing in % (its From): leave From blank to take the footprint''s dates, or check the date',
        v_fits, public.fuzzy_label(p_from, p_from_precision) using errcode = '23514';
    end if;
  else
    -- from the first outline it fits (or, if that one is undated, with the building)
    select * into v_first from jsonb_to_recordset(v_fp) as f (n int, valid_from date, valid_from_precision public.date_precision, valid_to date, valid_to_precision public.date_precision, fits boolean) where fits order by n limit 1;
    if v_first.valid_from is not null then
      v_from := v_first.valid_from;
      v_from_p := v_first.valid_from_precision;
    end if;
  end if;
  if p_to is null then
    -- a later outline that leaves it out: it ends with the last one that held it
    select * into v_last from jsonb_to_recordset(v_fp) as f (n int, valid_from date, valid_from_precision public.date_precision, valid_to date, valid_to_precision public.date_precision, fits boolean) where fits order by n desc limit 1;
    if v_last.valid_to is not null and exists (select 1 from jsonb_to_recordset(v_fp) as f (n int, valid_from date, valid_from_precision public.date_precision, valid_to date, valid_to_precision public.date_precision, fits boolean) where n > v_last.n and not fits) then
      v_to := v_last.valid_to;
      v_to_p := v_last.valid_to_precision;
    end if;
  end if;

  v_slug := v_building.slug || '-' || coalesce(nullif(trim(both '-' from regexp_replace(lower(p_name), '[^a-z0-9]+', '-', 'g')), ''), 'space');
  if exists (select 1 from public.entities where slug = v_slug) then
    v_slug := v_slug || '-' || substr(md5(random()::text), 1, 4);
  end if;

  insert into public.entities (kind, slug, name, exists_from, exists_from_precision, exists_to, exists_to_precision, lifespan_confidence)
  values ('space', v_slug, p_name, coalesce(v_from, v_building.exists_from),
          case when v_from is null then v_building.exists_from_precision else v_from_p end,
          v_to, v_to_p, 'approximate')
  returning id into v_id;

  insert into public.entity_geometries (entity_id, role, geom, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence)
  values (v_id, 'footprint', v_geom, v_from, v_from_p, v_to, v_to_p, 'approximate');

  insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision)
  values (v_id, 'part_of', p_building, v_from, v_from_p, v_to, v_to_p);

  if p_floor is not null then
    insert into public.entity_attributes (entity_id, key, value) values (v_id, 'floor', to_jsonb(p_floor));
  end if;
  if nullif(btrim(p_unit_label), '') is not null then
    insert into public.entity_attributes (entity_id, key, value) values (v_id, 'unit_label', to_jsonb(btrim(p_unit_label)));
  end if;
  return v_slug;
end;
$$;
