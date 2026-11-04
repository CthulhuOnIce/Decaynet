-- =============================================================================
-- Decaynet :: 0039 "still standing in" also moves the start back
--
-- "Still standing in 1955" means the place existed in 1955. Before, it only
-- reopened pages marked gone by then. Now, when 1955 is before the recorded
-- start (a building plotted from 1960 that an earlier aerial shows), the start
-- moves back to 1955, and what began with the old start (its first condition,
-- shape, address, names, attributes, tags, links) moves with it. A fuzzy start
-- that already includes the year ("1950s") is left; an unknown start too.
-- Ends are handled as in 0037. reopen_pages takes the precision of the date now.
-- =============================================================================

drop function if exists public.reopen_pages(uuid[], date);

create function public.reopen_pages(p_ids uuid[], p_at date, p_precision public.date_precision default 'year') returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  e record;
  v_old date;
  v_from date;
  v_moved boolean;
  v_done int := 0;
  v_skipped jsonb := '[]';
  v_when text := public.fuzzy_label(p_at, p_precision);
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  if p_at is null then
    raise exception 'Which year were they still standing in?' using errcode = '22023';
  end if;

  for e in select * from public.entities where id = any (p_ids) order by name loop
    -- the start: standing then means it existed by then
    v_moved := false;
    if e.exists_from is not null and p_at < e.exists_from then
      v_from := e.exists_from;
      update public.entities set exists_from = p_at, exists_from_precision = p_precision where id = e.id;
      update public.entity_states set valid_from = p_at, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_from;
      update public.entity_geometries set valid_from = p_at, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_from;
      update public.addresses set valid_from = p_at, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_from;
      update public.entity_names set valid_from = p_at, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_from;
      update public.entity_attributes set valid_from = p_at, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_from;
      update public.entity_tags set valid_from = p_at, valid_from_precision = p_precision where entity_id = e.id and valid_from = v_from;
      update public.relations set valid_from = p_at, valid_from_precision = p_precision
       where (subject_id = e.id or object_id = e.id) and valid_from = v_from;
      v_moved := true;
    end if;

    -- the end
    if e.exists_to is null then
      if v_moved then v_done := v_done + 1;
      else v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'reason', 'already standing in ' || v_when);
      end if;
      continue;
    end if;
    -- only an end wholly before then contradicts it ("1970s" doesn't rule out 1975)
    if p_at < public.precision_end(e.exists_to, e.exists_to_precision) then
      if v_moved then v_done := v_done + 1;
      else
        v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
          'reason', case when e.exists_to > p_at
                         then 'already standing until ' || public.fuzzy_label(e.exists_to, e.exists_to_precision)
                         else 'recorded as gone in ' || public.fuzzy_label(e.exists_to, e.exists_to_precision)
                              || ', which can still be after ' || v_when || ': narrow it with “gone by”' end);
      end if;
      continue;
    end if;
    v_old := e.exists_to;
    -- a recorded demolition (sourced, or more than a guess) is evidence: a person should look
    if exists (select 1 from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
                where s.entity_id = e.id and not ls.is_extant and ls.decay_level >= 5 and s.valid_from >= v_old
                  and (s.source_id is not null or s.confidence not in ('approximate', 'speculative'))) then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', case when v_moved then 'start moved to ' || v_when || ', but its' else 'its' end
                  || ' demolition is recorded with a source or more than approximate confidence: check it by hand');
      continue;
    end if;

    delete from public.entity_states s using public.lifecycle_statuses ls
     where ls.id = s.status and s.entity_id = e.id and not ls.is_extant and ls.decay_level >= 5 and s.valid_from >= v_old;
    update public.entities set exists_to = null where id = e.id;
    -- what ended with it runs on again
    update public.entity_states set valid_to = null where entity_id = e.id and valid_to = v_old;
    update public.entity_geometries set valid_to = null where entity_id = e.id and valid_to = v_old;
    update public.addresses set valid_to = null where entity_id = e.id and valid_to = v_old;
    update public.entity_names set valid_to = null where entity_id = e.id and valid_to = v_old;
    update public.entity_attributes set valid_to = null where entity_id = e.id and valid_to = v_old;
    update public.entity_tags set valid_to = null where entity_id = e.id and valid_to = v_old;
    update public.relations set valid_to = null where (subject_id = e.id or object_id = e.id) and valid_to = v_old;
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('done', v_done, 'skipped', v_skipped);
end;
$$;

grant execute on function public.reopen_pages(uuid[], date, public.date_precision) to authenticated;
