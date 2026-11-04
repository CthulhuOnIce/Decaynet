-- =============================================================================
-- Decaynet :: 0037 bulk edits and fuzzy ends
--
-- A recorded end is a range: "1970s" means sometime in 1970-79 (stored as
-- 1970-01-01, decade). The bulk actions compared the bare date, so "gone by
-- 1978" said "already gone by 1970s" for a building the map rightly shows
-- standing in 1978.
--
-- end_pages: only a date after the whole range is "already gone"; one inside
--   it narrows the end (1970s -> 1978), one before it moves the end earlier.
--   The gone condition already recorded moves with it (no second one), and what
--   ended with the old end ends at the new one.
-- reopen_pages: reopens only when the recorded end is wholly before the year
--   ("1970s" doesn't rule out standing in 1975; it says so).
-- set_condition_pages: a date inside a fuzzy end says to narrow it first,
--   instead of "gone by" (and never makes a backwards range).
-- =============================================================================

create or replace function public.end_pages(
  p_ids uuid[],
  p_at date,
  p_precision public.date_precision default 'year',
  p_status text default 'demolished',
  p_note text default null
) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  e record;
  v_done int := 0;
  v_skipped jsonb := '[]';
  v_label text := public.fuzzy_label(p_at, p_precision);
  v_after boolean;
  v_old date;
  v_moved int;
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  if p_at is null then
    raise exception 'When were they gone by?' using errcode = '22023';
  end if;
  if not exists (select 1 from public.lifecycle_statuses s where s.id = p_status and not s.is_extant) then
    raise exception '“%” isn''t a condition for something that''s gone', p_status using errcode = '22023';
  end if;

  for e in select * from public.entities where id = any (p_ids) order by name loop
    v_old := e.exists_to;
    -- a recorded end is a range ("1970s" = 1970-79): only a date after all of it adds nothing;
    -- one inside it narrows it (1978), one before it moves it earlier
    if v_old is not null and p_at >= public.precision_end(v_old, e.exists_to_precision) then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'already gone by ' || public.fuzzy_label(v_old, e.exists_to_precision));
      continue;
    end if;
    if e.exists_from is not null and e.exists_from >= p_at then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'starts in ' || public.fuzzy_label(e.exists_from, e.exists_from_precision));
      continue;
    end if;
    -- anything recorded as starting later says it was still there
    -- (the recorded ending itself, when there is one, moves rather than counting as "later")
    v_after := exists (select 1 from public.entity_states t join public.lifecycle_statuses ls on ls.id = t.status
                        where t.entity_id = e.id and t.valid_from > p_at
                          and not (v_old is not null and t.valid_from >= v_old and not ls.is_extant and ls.decay_level >= 5))
            or exists (select 1 from public.entity_geometries t where t.entity_id = e.id and t.valid_from > p_at)
            or exists (select 1 from public.addresses t where t.entity_id = e.id and t.valid_from > p_at)
            or exists (select 1 from public.entity_names t where t.entity_id = e.id and t.valid_from > p_at)
            or exists (select 1 from public.entity_attributes t where t.entity_id = e.id and t.valid_from > p_at)
            or exists (select 1 from public.entity_tags t where t.entity_id = e.id and t.valid_from > p_at)
            or exists (select 1 from public.relations t where (t.subject_id = e.id or t.object_id = e.id) and t.valid_from > p_at);
    if v_after then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'has facts after ' || v_label);
      continue;
    end if;

    update public.entities set exists_to = p_at, exists_to_precision = p_precision where id = e.id;
    v_moved := 0;
    if v_old is not null then
      -- an end already recorded: its gone condition moves to the new date, and what ended with it follows
      update public.entity_states s set valid_from = p_at, valid_from_precision = p_precision
        from public.lifecycle_statuses ls
       where ls.id = s.status and not ls.is_extant and ls.decay_level >= 5 and s.entity_id = e.id and s.valid_from >= v_old;
      get diagnostics v_moved = row_count;
      update public.entity_states set valid_to = p_at, valid_to_precision = p_precision where entity_id = e.id and valid_to = v_old;
      update public.entity_geometries set valid_to = p_at, valid_to_precision = p_precision where entity_id = e.id and valid_to = v_old;
      update public.addresses set valid_to = p_at, valid_to_precision = p_precision where entity_id = e.id and valid_to = v_old;
      update public.entity_names set valid_to = p_at, valid_to_precision = p_precision where entity_id = e.id and valid_to = v_old;
      update public.entity_attributes set valid_to = p_at, valid_to_precision = p_precision where entity_id = e.id and valid_to = v_old;
      update public.entity_tags set valid_to = p_at, valid_to_precision = p_precision where entity_id = e.id and valid_to = v_old;
      update public.relations set valid_to = p_at, valid_to_precision = p_precision
       where (subject_id = e.id or object_id = e.id) and valid_to = v_old;
    end if;
    -- what was still running ends with it (not the gone condition that starts then)
    update public.entity_states set valid_to = p_at, valid_to_precision = p_precision
     where entity_id = e.id and (valid_to is null or valid_to > p_at) and (valid_from is null or valid_from < p_at);
    update public.entity_geometries set valid_to = p_at, valid_to_precision = p_precision
     where entity_id = e.id and (valid_to is null or valid_to > p_at);
    update public.addresses set valid_to = p_at, valid_to_precision = p_precision
     where entity_id = e.id and (valid_to is null or valid_to > p_at);
    update public.entity_names set valid_to = p_at, valid_to_precision = p_precision
     where entity_id = e.id and (valid_to is null or valid_to > p_at);
    update public.entity_attributes set valid_to = p_at, valid_to_precision = p_precision
     where entity_id = e.id and (valid_to is null or valid_to > p_at);
    update public.entity_tags set valid_to = p_at, valid_to_precision = p_precision
     where entity_id = e.id and (valid_to is null or valid_to > p_at);
    update public.relations set valid_to = p_at, valid_to_precision = p_precision
     where (subject_id = e.id or object_id = e.id) and (valid_to is null or valid_to > p_at);
    if v_moved = 0 then
    insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, confidence, note)
    values (e.id,
            case when e.kind = 'street' and p_status = 'demolished' then 'vacated' else p_status end,
            p_at, p_precision, 'approximate',
            coalesce(nullif(btrim(p_note), ''), 'Gone by ' || v_label));
    end if;
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('done', v_done, 'skipped', v_skipped);
end;
$$;

create or replace function public.reopen_pages(p_ids uuid[], p_at date) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  e record;
  v_old date;
  v_done int := 0;
  v_skipped jsonb := '[]';
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  if p_at is null then
    raise exception 'Which year were they still standing in?' using errcode = '22023';
  end if;

  for e in select * from public.entities where id = any (p_ids) order by name loop
    if e.exists_to is null then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'reason', 'not marked gone');
      continue;
    end if;
    -- only an end wholly before then contradicts it ("1970s" doesn't rule out 1975)
    if p_at < public.precision_end(e.exists_to, e.exists_to_precision) then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', case when e.exists_to > p_at
                       then 'already standing until ' || public.fuzzy_label(e.exists_to, e.exists_to_precision)
                       else 'recorded as gone in ' || public.fuzzy_label(e.exists_to, e.exists_to_precision)
                            || ', which can still be after ' || public.fuzzy_label(p_at, 'year') || ': narrow it with “gone by”' end);
      continue;
    end if;
    v_old := e.exists_to;
    -- a recorded demolition (sourced, or more than a guess) is evidence: a person should look
    if exists (select 1 from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
                where s.entity_id = e.id and not ls.is_extant and ls.decay_level >= 5 and s.valid_from >= v_old
                  and (s.source_id is not null or s.confidence not in ('approximate', 'speculative'))) then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'its demolition is recorded with a source or more than approximate confidence: check it by hand');
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
        'reason', case when p_at >= public.precision_end(e.exists_to, e.exists_to_precision)
                       then 'gone by ' || public.fuzzy_label(e.exists_to, e.exists_to_precision)
                       -- "1970s" and 1978: maybe still there, but its end needs a year before a condition can follow it
                       else 'recorded as gone in ' || public.fuzzy_label(e.exists_to, e.exists_to_precision)
                            || ': narrow it with “gone by” first' end);
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
