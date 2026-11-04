-- =============================================================================
-- Decaynet :: 0035 bulk "gone by" / "still standing" for selected pages
--
-- For working through aerials year by year: select the buildings missing from
-- this year's aerial and mark them gone by that year, or the ones you'd marked
-- gone that turn up in a later aerial and mark them still standing.
--
-- end_pages(ids, year): for each page
--   * skipped (with the reason) if it already ended by then, starts in or after
--     that year, or has any fact starting after it (evidence it was still there)
--   * otherwise its lifespan ends then (that precision); its conditions, shapes,
--     addresses, names, attributes, tags and links still running are closed
--     then; and a gone condition is added (Demolished, or Vacated for a street),
--     approximate, with a note ("Not seen in the 1958 aerial")
-- reopen_pages(ids, year): the reverse, for pages that ended by that year
--   * the gone condition(s) at the end are removed when they're a guess
--     (approximate or speculative, no source); a sourced or confident one is
--     evidence, so the page is skipped for a person to check
--   * the lifespan is open again and everything that ended with it reopens
--
-- Both need edit_content (each change is one an editor could make by hand) and
-- run as the caller, so the usual read/write rules apply; history is recorded by
-- the change log as for any edit.
-- =============================================================================

/** A date as people write it at its precision: "May 12, 1927", "May 1927", "1958", "1950s", "20th century". */
create or replace function public.fuzzy_label(p_date date, p_precision public.date_precision) returns text
language sql immutable as $$
  select case p_precision
           when 'day' then to_char(p_date, 'FMMonth FMDD, YYYY')
           when 'month' then to_char(p_date, 'FMMonth YYYY')
           when 'decade' then (extract(year from p_date)::int / 10 * 10)::text || 's'
           when 'century' then (extract(year from p_date)::int / 100 + 1)::text
                               || case when (extract(year from p_date)::int / 100 + 1) % 100 in (11, 12, 13) then 'th'
                                       when (extract(year from p_date)::int / 100 + 1) % 10 = 1 then 'st'
                                       when (extract(year from p_date)::int / 100 + 1) % 10 = 2 then 'nd'
                                       when (extract(year from p_date)::int / 100 + 1) % 10 = 3 then 'rd'
                                       else 'th' end || ' century'
           else extract(year from p_date)::int::text
         end
$$;
grant execute on function public.fuzzy_label(date, public.date_precision) to anon, authenticated;

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
    if e.exists_to is not null and e.exists_to <= p_at then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'already gone by ' || public.fuzzy_label(e.exists_to, e.exists_to_precision));
      continue;
    end if;
    if e.exists_from is not null and e.exists_from >= p_at then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'starts in ' || public.fuzzy_label(e.exists_from, e.exists_from_precision));
      continue;
    end if;
    -- anything recorded as starting later says it was still there
    v_after := exists (select 1 from public.entity_states t where t.entity_id = e.id and t.valid_from > p_at)
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
    -- what was still running ends with it
    update public.entity_states set valid_to = p_at, valid_to_precision = p_precision
     where entity_id = e.id and (valid_to is null or valid_to > p_at);
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
    insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, confidence, note)
    values (e.id,
            case when e.kind = 'street' and p_status = 'demolished' then 'vacated' else p_status end,
            p_at, p_precision, 'approximate',
            coalesce(nullif(btrim(p_note), ''), 'Gone by ' || v_label));
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
    if e.exists_to > p_at then
      v_skipped := v_skipped || jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug,
        'reason', 'already standing until ' || public.fuzzy_label(e.exists_to, e.exists_to_precision));
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

grant execute on function public.end_pages(uuid[], date, public.date_precision, text, text) to authenticated;
grant execute on function public.reopen_pages(uuid[], date) to authenticated;
