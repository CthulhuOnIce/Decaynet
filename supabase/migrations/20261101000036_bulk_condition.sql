-- =============================================================================
-- Decaynet :: 0036 bulk "condition from" for selected pages
--
-- Alongside "gone by" and "still standing" (0035): mark a group of buildings
-- as, say, Abandoned from 1958, when an aerial shows holes or neglect.
--
-- set_condition_pages(ids, status, year): for each page the condition is
-- spliced into its timeline: the condition running then ends then, and the new
-- one runs until the next recorded condition (or the end of the lifespan), so
-- what's recorded later (a 1975 demolition) stays. Approximate, with a note.
-- Skipped, with the reason: pages gone by then or starting later, pages already
-- in that condition then, and pages with a different condition recorded from
-- that same date (change it by hand rather than overwrite it). Only conditions
-- of something still standing; "gone by" handles the rest.
-- =============================================================================

create or replace function public.set_condition_pages(
  p_ids uuid[],
  p_status text,
  p_at date,
  p_precision public.date_precision default 'year',
  p_note text default null
) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  e record;
  v_label text;
  v_now record;
  v_next record;
  v_done int := 0;
  v_skipped jsonb := '[]';
  v_when text := public.fuzzy_label(p_at, p_precision);
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  if p_at is null then
    raise exception 'From when?' using errcode = '22023';
  end if;
  select label into v_label from public.lifecycle_statuses where id = p_status and is_extant;
  if v_label is null then
    raise exception '“%” isn''t a condition of something still standing (use “gone by” for that)', p_status using errcode = '22023';
  end if;

  for e in select * from public.entities where id = any (p_ids) order by name loop
    if e.exists_to is not null and e.exists_to <= p_at then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'gone by ' || public.fuzzy_label(e.exists_to, e.exists_to_precision));
      continue;
    end if;
    if e.exists_from is not null and e.exists_from > p_at then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'starts in ' || public.fuzzy_label(e.exists_from, e.exists_from_precision));
      continue;
    end if;
    -- the condition running then (the latest to have started by then)
    select s.*, ls.label as status_label into v_now
      from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
     where s.entity_id = e.id and s.valid_from is not null and s.valid_from <= p_at
       and (s.valid_to is null or s.valid_to > p_at)
     order by s.valid_from desc limit 1;
    if v_now.id is not null and v_now.status = p_status then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'already ' || v_label || ' then');
      continue;
    end if;
    if v_now.id is not null and v_now.valid_from = p_at then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'already recorded as ' || v_now.status_label || ' from ' || v_when || ': change it by hand');
      continue;
    end if;
    -- the next condition recorded after then: the new one runs up to it
    select s.valid_from, s.valid_from_precision into v_next
      from public.entity_states s
     where s.entity_id = e.id and s.valid_from > p_at
     order by s.valid_from limit 1;

    update public.entity_states set valid_to = p_at, valid_to_precision = p_precision
     where entity_id = e.id and valid_from is not null and valid_from < p_at
       and (valid_to is null or valid_to > p_at);
    insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, note)
    values (e.id, p_status, p_at, p_precision,
            coalesce(v_next.valid_from, e.exists_to),
            coalesce(case when v_next.valid_from is not null then v_next.valid_from_precision end, e.exists_to_precision, 'year'),
            'approximate',
            coalesce(nullif(btrim(p_note), ''), v_label || ' by ' || v_when));
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('done', v_done, 'skipped', v_skipped);
end;
$$;

grant execute on function public.set_condition_pages(uuid[], text, date, public.date_precision, text) to authenticated;
