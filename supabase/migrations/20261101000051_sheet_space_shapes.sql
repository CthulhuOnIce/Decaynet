-- =============================================================================
-- Decaynet :: 0051 spreadsheet spaces by shape
--
-- For the spreadsheet import's preview: storefront (space) rows with a GeoJSON
-- shape. A row with no building of its own goes into the building whose
-- footprint holds it (in the row's year, if it has one); and every space's
-- shape is checked against its building's footprints, as Edit facts → Spaces
-- does (within 2 m of any of them), so one that reaches outside is flagged.
-- =============================================================================

/** p_rows: [{i, shape (GeoJSON), at (date)?, place_id?}]
 *  Returns [{i, place: {id, slug, name, kind}?, how: 'given'|'shape'|null, fits, outside_m, footprints, error?}] */
create or replace function public.sheet_space_places(p_rows jsonb)
returns jsonb
language plpgsql stable security invoker set search_path = public, extensions as $$
declare
  r jsonb;
  v_geom geometry;
  v_at date;
  v_place uuid;
  v_how text;
  v_fits boolean;
  v_out numeric;
  v_n int;
  v_res jsonb := '[]';
begin
  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    begin
      v_geom := st_setsrid(st_geomfromgeojson((r -> 'shape')::text), 4326);
    exception when others then
      v_res := v_res || jsonb_build_object('i', r -> 'i', 'error', 'its shape couldn''t be read');
      continue;
    end;
    if st_dimension(v_geom) <> 2 then
      v_res := v_res || jsonb_build_object('i', r -> 'i', 'error', 'a space''s shape has to be an area');
      continue;
    end if;
    if not st_isvalid(v_geom) then v_geom := st_makevalid(v_geom); end if;
    v_at := nullif(r ->> 'at', '')::date;
    v_place := nullif(r ->> 'place_id', '')::uuid;
    v_how := case when v_place is not null then 'given' end;

    if v_place is null then
      -- the building (or site) whose footprint holds it: one standing then, the smallest if
      -- footprints overlap; failing that, any footprint it ever had
      select g.entity_id into v_place
        from public.entity_geometries g join public.entities e on e.id = g.entity_id
       where e.kind in ('building', 'site') and g.role <> 'viewpoint' and st_dimension(g.geom) = 2
         and st_contains(g.geom, st_pointonsurface(v_geom))
       order by (v_at is not null and g.valid @> v_at) desc, st_area(g.geom)
       limit 1;
      if v_place is not null then v_how := 'shape'; end if;
    end if;

    v_fits := null;
    v_out := null;
    v_n := 0;
    if v_place is not null then
      -- the space fits if it's inside any of the building's footprints (2 m of slack); if it
      -- fits none, how far its corners reach outside the nearest one
      select count(*), bool_or(st_coveredby(v_geom, st_buffer(g.geom::geography, 2)::geometry)),
             min((select max(st_distance(d.geom::geography, g.geom::geography)) from st_dumppoints(v_geom) d))
        into v_n, v_fits, v_out
        from public.entity_geometries g
       where g.entity_id = v_place and g.role <> 'viewpoint' and st_dimension(g.geom) = 2;
    end if;

    v_res := v_res || jsonb_strip_nulls(jsonb_build_object(
      'i', r -> 'i',
      'place', (select jsonb_build_object('id', e.id, 'slug', e.slug, 'name', e.name, 'kind', e.kind) from public.entities e where e.id = v_place),
      'how', v_how,
      'footprints', v_n,
      'fits', v_fits,
      'outside_m', case when v_fits is false then round(v_out, 1) end));
  end loop;
  return v_res;
end;
$$;
grant execute on function public.sheet_space_places(jsonb) to authenticated;
