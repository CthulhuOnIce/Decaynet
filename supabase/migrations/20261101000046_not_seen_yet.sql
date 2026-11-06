-- =============================================================================
-- Decaynet :: 0046 "not seen yet": built after the year of a map
--
-- The workbench's "Gone by" now asks which kind of absence it is:
--   * Demolished here: it was there and is gone (end_pages, as before)
--   * Not seen yet: it isn't there *yet* (an earlier aerial than the one it was
--     plotted from). start_after_pages moves the start to just after that year
--     ("not seen yet in 1955": from 1956), taking along what began with the old
--     start (its first condition, shape, address, names, links). A start that is
--     already later is left. Anything else recorded before then is evidence it
--     was there, so that page is skipped and says why.
-- =============================================================================

create or replace function public.start_after_pages(p_ids uuid[], p_at date, p_precision public.date_precision default 'year') returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  e record;
  v_start date;          -- the new start: just after the year (or month, decade…) given
  v_old date;
  v_conflict text;
  v_done int := 0;
  v_skipped jsonb := '[]';
  v_when text := public.fuzzy_label(p_at, p_precision);
  v_after text;
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  if p_at is null then
    raise exception 'Not seen yet in which year?' using errcode = '22023';
  end if;
  v_start := public.precision_end(p_at, p_precision);
  v_after := public.fuzzy_label(v_start, p_precision);

  for e in select * from public.entities where id = any (p_ids) order by name loop
    v_old := e.exists_from;
    -- it starts after then already ("from 1960", or "1960s"): nothing to change
    if v_old is not null and v_old >= v_start then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'already starts after ' || v_when || ' (' || public.fuzzy_label(v_old, e.exists_from_precision) || ')');
      continue;
    end if;
    -- gone by then: it can't start after it ended
    if e.exists_to is not null and e.exists_to < v_start then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'gone by ' || public.fuzzy_label(e.exists_to, e.exists_to_precision) || ', before ' || v_after);
      continue;
    end if;
    -- something recorded before the new start (other than what began with the old start)
    -- says it was there; a fact that began with the old start but ended before then too
    select x.what into v_conflict from (
      select 'a condition' as what, s.valid_from, s.valid_to from public.entity_states s where s.entity_id = e.id
      union all select 'a shape', g.valid_from, g.valid_to from public.entity_geometries g where g.entity_id = e.id
      union all select 'an address', a.valid_from, a.valid_to from public.addresses a where a.entity_id = e.id
      union all select 'a name', n.valid_from, n.valid_to from public.entity_names n where n.entity_id = e.id
      union all select 'a fact', t.valid_from, t.valid_to from public.entity_attributes t where t.entity_id = e.id
      union all select 'a tag', t.valid_from, t.valid_to from public.entity_tags t where t.entity_id = e.id
      union all select 'a link', r.valid_from, r.valid_to from public.relations r where (r.subject_id = e.id or r.object_id = e.id)
    ) x
     where (x.valid_from is not null and x.valid_from < v_start and x.valid_from is distinct from v_old)
        or (x.valid_to is not null and x.valid_to < v_start)
     order by x.valid_from nulls last
     limit 1;
    if v_conflict is not null then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'has ' || v_conflict || ' recorded before ' || v_after);
      continue;
    end if;

    update public.entities set exists_from = v_start, exists_from_precision = p_precision where id = e.id;
    if v_old is not null then
      update public.entity_states set valid_from = v_start, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_old;
      update public.entity_geometries set valid_from = v_start, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_old;
      update public.addresses set valid_from = v_start, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_old;
      update public.entity_names set valid_from = v_start, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_old;
      update public.entity_attributes set valid_from = v_start, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_old;
      update public.entity_tags set valid_from = v_start, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_old;
      update public.relations set valid_from = v_start, valid_from_precision = p_precision
       where (subject_id = e.id or object_id = e.id) and valid_from = v_old;
    end if;
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('done', v_done, 'skipped', v_skipped, 'starts', v_after);
end;
$$;
grant execute on function public.start_after_pages(uuid[], date, public.date_precision) to authenticated;
