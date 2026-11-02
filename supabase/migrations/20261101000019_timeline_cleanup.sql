-- =============================================================================
-- Decaynet :: 0019 timeline cleanup
--
-- A page's timeline drifts as facts pile up: two "Vacant" rows back to back,
-- "Active" still open after "Demolished" started, a footprint that stops in
-- 1950 although the building stood until 1987, a lifespan end with no
-- condition saying what happened. This adds a reviewable cleanup:
--
--   timeline_plan(page)              proposed fixes, each with before/after
--   normalize_timeline(page, keys)   apply the chosen fixes in one go
--   timeline_review(limit)           pages whose timeline has something to fix
--
-- Rules (each fix is its own item, so a reviewer can skip any of them):
--   end_lifespan      a "gone" condition (demolished, empty lot, vacated) but
--                     no lifespan end: end the lifespan there
--   merge_duplicate   the same condition twice in a row: keep the first
--   close_overlap     a condition still running when the next one starts:
--                     end it where the next begins
--   close_at_end      a standing condition (in use, vacant, ...) running past
--                     the end of the lifespan: end it there
--   add_gone          a building, structure or street whose lifespan ended
--                     with no "gone" condition: add Demolished (Vacated for
--                     streets) at the end date
--   fit_footprint     exactly one footprint: make it cover the whole lifespan
--
-- Nothing touches facts on other pages, names, relations or citations.
-- =============================================================================

insert into public.permissions (id, label, description, sort) values
  ('clean_timelines', 'Clean up timelines',
   'Review and apply automatic fixes to a page''s timeline: overlapping conditions, footprint dates, missing demolitions.', 75)
on conflict (id) do nothing;

insert into public.role_permissions (role, permission) values ('moderator', 'clean_timelines')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Plan (read-only)
-- -----------------------------------------------------------------------------
create or replace function public.timeline_plan(p_entity uuid)
returns jsonb
language plpgsql stable security invoker set search_path = public, extensions as $$
declare
  e record;
  term record;
  g record;
  v_end date;
  v_endp public.date_precision;
  plan jsonb := '[]'::jsonb;
  rows jsonb;
  kept jsonb := '[]'::jsonb;
  r jsonb;
  cur jsonb;
  nxt jsonb;
  n int;
  i int;
  new_to date;
  new_tp text;
  why text;
  why_label text;
  v_gone text;
  v_from date;
  v_fp public.date_precision;
  v_to date;
  v_tp public.date_precision;
begin
  select en.id, en.kind, en.exists_from, en.exists_from_precision, en.exists_to, en.exists_to_precision
    into e from public.entities en where en.id = p_entity;
  if not found then
    return plan;
  end if;
  v_end := e.exists_to;
  v_endp := e.exists_to_precision;

  -- end_lifespan ------------------------------------------------------------
  if v_end is null then
    select s.id, s.valid_from, s.valid_from_precision, ls.label into term
      from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
     where s.entity_id = p_entity and not ls.is_extant and ls.decay_level >= 5 and s.valid_from is not null
       and (e.exists_from is null or s.valid_from >= e.exists_from)
     order by s.valid_from
     limit 1;
    if found then
      v_end := term.valid_from;
      v_endp := term.valid_from_precision;
      plan := plan || jsonb_build_object(
        'key', 'lifespan_end', 'rule', 'end_lifespan', 'target', 'entity', 'op', 'update', 'id', p_entity,
        'label', term.label,
        'before', jsonb_build_object('valid_from', e.exists_from, 'valid_from_precision', e.exists_from_precision,
                                     'valid_to', null, 'valid_to_precision', e.exists_to_precision),
        'after', jsonb_build_object('valid_from', e.exists_from, 'valid_from_precision', e.exists_from_precision,
                                    'valid_to', v_end, 'valid_to_precision', v_endp));
    end if;
  end if;

  -- conditions, oldest first --------------------------------------------------
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'status', s.status, 'label', ls.label, 'extant', ls.is_extant,
           'valid_from', s.valid_from, 'valid_from_precision', s.valid_from_precision,
           'valid_to', s.valid_to, 'valid_to_precision', s.valid_to_precision)
           order by s.valid_from nulls first, ls.sort, s.created_at), '[]'::jsonb)
    into rows
    from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
   where s.entity_id = p_entity;

  -- merge_duplicate: the same condition twice in a row
  for r in select * from jsonb_array_elements(rows) loop
    n := jsonb_array_length(kept);
    if n > 0 and kept -> (n - 1) ->> 'status' = r ->> 'status' then
      cur := kept -> (n - 1);
      plan := plan || jsonb_build_object(
        'key', 'merge:' || (r ->> 'id'), 'rule', 'merge_duplicate', 'target', 'status', 'op', 'delete',
        'id', r -> 'id', 'label', r ->> 'label', 'into', cur -> 'id',
        'before', jsonb_build_object('valid_from', r -> 'valid_from', 'valid_from_precision', r -> 'valid_from_precision',
                                     'valid_to', r -> 'valid_to', 'valid_to_precision', r -> 'valid_to_precision'));
      -- the merged row keeps the later end; an open end wins
      if cur ->> 'new_to' is not null and r ->> 'valid_to' is not null and (r ->> 'valid_to')::date <= (cur ->> 'new_to')::date then
        null;
      else
        cur := cur || jsonb_build_object('new_to', r -> 'valid_to', 'new_tp', r -> 'valid_to_precision', 'merged', true);
      end if;
      kept := jsonb_set(kept, array[(n - 1)::text], cur);
    else
      kept := kept || jsonb_build_array(r || jsonb_build_object('new_to', r -> 'valid_to', 'new_tp', r -> 'valid_to_precision'));
    end if;
  end loop;

  -- close_overlap / close_at_end
  n := jsonb_array_length(kept);
  for i in 0 .. n - 1 loop
    cur := kept -> i;
    new_to := (cur ->> 'new_to')::date;
    new_tp := cur ->> 'new_tp';
    why := case when (cur ->> 'merged')::boolean then 'merge_duplicate' end;
    why_label := null;
    if i < n - 1 and kept -> (i + 1) ->> 'valid_from' is not null then
      nxt := kept -> (i + 1);
      if new_to is null or new_to > (nxt ->> 'valid_from')::date then
        new_to := (nxt ->> 'valid_from')::date;
        new_tp := nxt ->> 'valid_from_precision';
        why := 'close_overlap';
        why_label := nxt ->> 'label';
      end if;
    end if;
    if (cur ->> 'extant')::boolean and v_end is not null
       and (cur ->> 'valid_from' is null or (cur ->> 'valid_from')::date <= v_end)
       and (new_to is null or new_to > v_end) then
      new_to := v_end;
      new_tp := v_endp::text;
      why := 'close_at_end';
      why_label := null;
    end if;
    if new_to is distinct from (cur ->> 'valid_to')::date
       or (new_to is not null and new_tp is distinct from cur ->> 'valid_to_precision') then
      plan := plan || jsonb_build_object(
        'key', 'status:' || (cur ->> 'id'), 'rule', why, 'target', 'status', 'op', 'update',
        'id', cur -> 'id', 'label', cur ->> 'label', 'next', why_label,
        'before', jsonb_build_object('valid_from', cur -> 'valid_from', 'valid_from_precision', cur -> 'valid_from_precision',
                                     'valid_to', cur -> 'valid_to', 'valid_to_precision', cur -> 'valid_to_precision'),
        'after', jsonb_build_object('valid_from', cur -> 'valid_from', 'valid_from_precision', cur -> 'valid_from_precision',
                                    'valid_to', new_to, 'valid_to_precision', new_tp));
    end if;
  end loop;

  -- add_gone --------------------------------------------------------------------
  if v_end is not null and e.kind in ('building', 'infrastructure', 'street')
     and not exists (select 1 from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
                      where s.entity_id = p_entity and not ls.is_extant and ls.decay_level >= 5) then
    v_gone := case when e.kind = 'street' then 'vacated' else 'demolished' end;
    if exists (select 1 from public.lifecycle_statuses where id = v_gone) then
      plan := plan || jsonb_build_object(
        'key', 'add_gone', 'rule', 'add_gone', 'target', 'status', 'op', 'insert', 'status', v_gone,
        'label', (select label from public.lifecycle_statuses where id = v_gone),
        'after', jsonb_build_object('valid_from', v_end, 'valid_from_precision', v_endp, 'valid_to', null, 'valid_to_precision', v_endp));
    end if;
  end if;

  -- fit_footprint ---------------------------------------------------------------
  if (select count(*) from public.entity_geometries gg
       where gg.entity_id = p_entity and gg.role in ('footprint', 'shape') and st_dimension(gg.geom) = 2) = 1 then
    select gg.id, gg.role, gg.valid_from, gg.valid_from_precision, gg.valid_to, gg.valid_to_precision into g
      from public.entity_geometries gg
     where gg.entity_id = p_entity and gg.role in ('footprint', 'shape') and st_dimension(gg.geom) = 2;
    v_from := coalesce(e.exists_from, g.valid_from);
    v_fp := case when e.exists_from is not null then e.exists_from_precision else g.valid_from_precision end;
    v_to := v_end;
    v_tp := case when v_end is not null then v_endp else g.valid_to_precision end;
    if (v_from is null or v_to is null or v_to >= v_from)
       and (v_from is distinct from g.valid_from or (v_from is not null and v_fp is distinct from g.valid_from_precision)
            or v_to is distinct from g.valid_to or (v_to is not null and v_tp is distinct from g.valid_to_precision)) then
      plan := plan || jsonb_build_object(
        'key', 'footprint:' || g.id, 'rule', 'fit_footprint', 'target', 'geometry', 'op', 'update', 'id', g.id,
        'label', g.role,
        'before', jsonb_build_object('valid_from', g.valid_from, 'valid_from_precision', g.valid_from_precision,
                                     'valid_to', g.valid_to, 'valid_to_precision', g.valid_to_precision),
        'after', jsonb_build_object('valid_from', v_from, 'valid_from_precision', v_fp,
                                    'valid_to', v_to, 'valid_to_precision', v_tp));
    end if;
  end if;

  return plan;
end;
$$;

comment on function public.timeline_plan(uuid) is
  'Proposed timeline fixes for one page (read-only). Each item: key, rule, target, op, id, label, before, after.';

-- -----------------------------------------------------------------------------
-- Apply. Re-plans inside the transaction and applies the items whose key was
-- chosen (all when p_keys is null), so it never acts on a stale preview.
-- -----------------------------------------------------------------------------
create or replace function public.normalize_timeline(p_entity uuid, p_keys text[] default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  it jsonb;
  a jsonb;
  v_conf public.confidence_level;
  v_done int := 0;
begin
  if not public.has_permission('clean_timelines') then
    raise exception 'You need the “Clean up timelines” permission' using errcode = '42501';
  end if;
  select lifespan_confidence into v_conf from public.entities where id = p_entity;
  if not found or public.entity_hidden(p_entity) then
    raise exception 'Page not found' using errcode = 'P0002';
  end if;

  for it in select * from jsonb_array_elements(public.timeline_plan(p_entity)) loop
    continue when p_keys is not null and not ((it ->> 'key') = any (p_keys));
    a := it -> 'after';
    case (it ->> 'target') || ':' || (it ->> 'op')
      when 'entity:update' then
        update public.entities
           set exists_to = (a ->> 'valid_to')::date,
               exists_to_precision = (a ->> 'valid_to_precision')::public.date_precision
         where id = p_entity;
      when 'status:delete' then
        delete from public.entity_states where id = (it ->> 'id')::uuid and entity_id = p_entity;
      when 'status:update' then
        update public.entity_states
           set valid_to = (a ->> 'valid_to')::date,
               valid_to_precision = (a ->> 'valid_to_precision')::public.date_precision
         where id = (it ->> 'id')::uuid and entity_id = p_entity;
      when 'status:insert' then
        insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, confidence, note)
        values (p_entity, it ->> 'status', (a ->> 'valid_from')::date,
                (a ->> 'valid_from_precision')::public.date_precision, v_conf,
                'Added by timeline cleanup: the lifespan ends here.');
      when 'geometry:update' then
        update public.entity_geometries
           set valid_from = (a ->> 'valid_from')::date,
               valid_from_precision = (a ->> 'valid_from_precision')::public.date_precision,
               valid_to = (a ->> 'valid_to')::date,
               valid_to_precision = (a ->> 'valid_to_precision')::public.date_precision
         where id = (it ->> 'id')::uuid and entity_id = p_entity;
      else
        continue;
    end case;
    v_done := v_done + 1;
  end loop;

  return jsonb_build_object('applied', v_done, 'remaining', jsonb_array_length(public.timeline_plan(p_entity)));
end;
$$;

-- -----------------------------------------------------------------------------
-- Pages with something to fix (for the admin list)
-- -----------------------------------------------------------------------------
create or replace function public.timeline_review(p_limit int default 300)
returns table (entity_id uuid, slug text, name text, kind text, fixes int, rules text[])
language sql stable security invoker set search_path = public as $$
  select e.id, e.slug, e.name, e.kind, jsonb_array_length(p.plan),
         array(select distinct x ->> 'rule' from jsonb_array_elements(p.plan) x order by 1)
    from public.entities e
    cross join lateral (select public.timeline_plan(e.id) as plan) p
   where public.has_permission('clean_timelines')
     and e.kind not in ('event', 'media', 'person', 'organization')
     and jsonb_array_length(p.plan) > 0
   order by jsonb_array_length(p.plan) desc, e.name
   limit greatest(1, least(coalesce(p_limit, 300), 2000))
$$;

-- Signed-in only (the functions also check the permission themselves)
revoke execute on function public.normalize_timeline(uuid, text[]) from public, anon;
revoke execute on function public.timeline_review(int) from public, anon;
grant execute on function public.normalize_timeline(uuid, text[]) to authenticated;
grant execute on function public.timeline_review(int) to authenticated;
