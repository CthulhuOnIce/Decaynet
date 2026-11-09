-- =============================================================================
-- Decaynet :: 0052 cited bulk actions; Area change retired
--
-- The workbench's selection does what Area change did, better (end_pages ends
-- a page's shapes, addresses and links with fuzzy dates, and says what it
-- skipped), so Area change goes. What it had that the selection didn't:
--   * a citation: bulk_pages runs a bulk action and cites, to the source
--     picked, the rows it added (the new condition, the new name), in the
--     same transaction; rows it only closed off keep their own sources
--   * streets ended as "demolished" are vacated instead
-- (and any shape of area: the workbench's lasso)
-- =============================================================================

create or replace function public.bulk_pages(
  p_action text,
  p_ids uuid[],
  p_at date,
  p_precision public.date_precision default 'year',
  p_value text default null,     -- gone: the condition; condition: the condition; name: the name
  p_note text default null,
  p_source uuid default null,
  p_detail text default null
) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v_before bigint := (select coalesce(max(id), 0) from public.change_log);
  r jsonb;
  r2 jsonb;
  v_streets uuid[];
  v_rest uuid[];
  t text;
  k int;
  n int := 0;
begin
  if p_source is not null and not exists (select 1 from public.sources where id = p_source) then
    raise exception 'That source doesn''t exist' using errcode = '22023';
  end if;
  if p_action = 'gone' then
    -- a street that's gone was vacated, not demolished
    select array_agg(id) filter (where kind = 'street'), array_agg(id) filter (where kind <> 'street')
      into v_streets, v_rest
      from public.entities where id = any (p_ids);
    if coalesce(p_value, 'demolished') = 'demolished' and v_streets is not null then
      r := public.end_pages(coalesce(v_rest, '{}'), p_at, p_precision, 'demolished', p_note);
      r2 := public.end_pages(v_streets, p_at, p_precision, 'vacated', p_note);
      r := jsonb_build_object('done', coalesce((r ->> 'done')::int, 0) + coalesce((r2 ->> 'done')::int, 0),
                              'skipped', coalesce(r -> 'skipped', '[]') || coalesce(r2 -> 'skipped', '[]'));
    else
      r := public.end_pages(p_ids, p_at, p_precision, coalesce(p_value, 'demolished'), p_note);
    end if;
  elsif p_action = 'condition' then
    r := public.set_condition_pages(p_ids, p_value, p_at, p_precision, p_note);
  elsif p_action = 'name' then
    r := public.name_pages(p_ids, p_at, p_value, p_precision, p_note);
  elsif p_action = 'standing' then
    r := public.reopen_pages(p_ids, p_at, p_precision);
  elsif p_action = 'notyet' then
    r := public.start_after_pages(p_ids, p_at, p_precision);
  else
    raise exception 'Unknown bulk action “%”', p_action using errcode = '22023';
  end if;

  if p_source is not null then
    foreach t in array array['entity_states', 'entity_names', 'addresses', 'relations', 'entity_geometries', 'entity_attributes', 'entity_tags'] loop
      execute format(
        'update public.%I x set source_id = $1, source_detail = coalesce(x.source_detail, $2)
          where x.source_id is null
            and x.id in (select l.row_id from public.change_log l
                          where l.id > $3 and l.op = ''INSERT'' and l.table_name = %L and l.actor_id is not distinct from auth.uid())',
        t, t)
      using p_source, nullif(btrim(p_detail), ''), v_before;
      get diagnostics k = row_count;
      n := n + k;
    end loop;
  end if;
  return r || jsonb_build_object('cited', n);
end;
$$;
grant execute on function public.bulk_pages(text, uuid[], date, public.date_precision, text, text, uuid, text) to authenticated;

drop function if exists public.retire_area(jsonb, date, public.date_precision, text[], text, text, uuid, uuid[]);
drop function if exists public.entities_in_area(jsonb, date, text[]);
