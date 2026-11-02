-- =============================================================================
-- Decaynet :: 0019 timeline cleanup
--
-- Every tool adds facts one at a time: a condition here, a traced shape there,
-- an import, an area retired in the workbench. Nothing re-reads the page as a
-- whole, so timelines collect loose ends: "Active" still open after
-- "Abandoned" started, a building with a lifespan but no condition at all,
-- an undated point that reads as "always there", a tenant still occupying a
-- building after it was demolished, an address outliving the building.
--
-- timeline_plan(page) reads one page and proposes the edits that make it a
-- single continuous story; normalize_timeline(page, keys) applies the chosen
-- ones in one transaction (re-planning first, so it never acts on a stale
-- preview); timeline_review() lists pages with something to fix.
--
-- The lifespan (exists_from .. exists_to) is the frame:
--   Lifespan     end it at a recorded demolition; (suggested, off by default)
--                start it at the earliest dated fact; flag a demolition that
--                disagrees with the end date
--   Conditions   one chain from start to end: Active from the start when
--                nothing is recorded or before the first recorded condition
--                (e.g. before abandonment); gaps carried forward; overlaps
--                closed; clipped to the lifespan; repeated conditions merged;
--                Demolished / Vacated added when the lifespan ends without one
--   Shapes       per kind of shape (footprint, point, centerline, boundary):
--                one shape covers the lifespan; several are chained in order
--   Addresses    one address covers the lifespan; several are clipped to it
--                (corner buildings have two at once)
--   Names        official renamings chained; dated names clipped
--   Relations    tenants, owners, "part of", "is on" clipped to both sides'
--                lifespans
--   Spaces       storefronts and suites end with their building
--   Facts        dated attributes clipped to the lifespan
-- Anything that needs a person (several undated conditions, two shapes that
-- start together, a fact entirely outside the lifespan) is reported as a note.
-- =============================================================================

insert into public.permissions (id, label, description, sort) values
  ('clean_timelines', 'Clean up timelines',
   'Review and apply automatic fixes that make a page''s conditions, shapes, addresses and relations agree with its lifespan.', 75)
on conflict (id) do nothing;

insert into public.role_permissions (role, permission) values ('moderator', 'clean_timelines')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
create or replace function internal.tl_range(f date, fp text, t date, tp text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('valid_from', f, 'valid_from_precision', fp, 'valid_to', t, 'valid_to_precision', tp)
$$;

create or replace function internal.tl_changed(r jsonb, f date, fp text, t date, tp text)
returns boolean language sql immutable as $$
  select f is distinct from (r ->> 'valid_from')::date
      or (f is not null and fp is distinct from r ->> 'valid_from_precision')
      or t is distinct from (r ->> 'valid_to')::date
      or (t is not null and tp is distinct from r ->> 'valid_to_precision')
$$;

-- Is the whole period of (d, p) before / after the whole period of (d2, p2)? "1958" is not before 29 Aug 1958.
create or replace function internal.tl_before(d date, p text, d2 date, p2 text)
returns boolean language sql immutable as $$
  select public.precision_end(d, p::public.date_precision) <= public.precision_start(d2, p2::public.date_precision)
$$;
create or replace function internal.tl_starts_after(d date, p text, d2 date, p2 text)
returns boolean language sql immutable as $$
  select public.precision_start(d, p::public.date_precision) > public.precision_start(d2, p2::public.date_precision)
$$;
create or replace function internal.tl_gap(d date, p text, d2 date, p2 text)
returns boolean language sql immutable as $$
  select public.precision_end(d, p::public.date_precision) < public.precision_start(d2, p2::public.date_precision)
$$;
create or replace function internal.tl_after(d date, p text, d2 date, p2 text)
returns boolean language sql immutable as $$
  select public.precision_start(d, p::public.date_precision) >= public.precision_end(d2, p2::public.date_precision)
$$;

/*
 * Fit dated rows to a lifespan [b, e] (either end may be unknown).
 *   p_rows: [{id, label, valid_from, valid_from_precision, valid_to, valid_to_precision}]
 *           ordered by valid_from (nulls first)
 *   modes:  fit    one row: cover the whole lifespan (open-ended when e is unknown)
 *           chain  rows follow each other: first starts at b, each ends where the
 *                  next starts, last ends at e (open when e is unknown)
 *           names  like chain inside, but only clipped at the ends
 *           clamp  clip each row to [b, e]; undated ends take the lifespan's
 *           clip   like clamp, but an undated start stays undated (relations:
 *                  "is on Broadway" needs no start date, only an end)
 * Returns changed rows as {id, label, before, after, why[]}, plus notes as
 * {note: 'concurrent'} or {note: 'outside', id, label, before}.
 */
create or replace function internal.tl_fit(p_rows jsonb, b date, bp text, e date, ep text, p_mode text)
returns jsonb language plpgsql immutable as $$
declare
  out jsonb := '[]'::jsonb;
  n int := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
  i int;
  r jsonb;
  nx jsonb;
  f date; fp text; t date; tp text; t0 date;
  why text[];
begin
  if n = 0 or (b is null and e is null) then
    return out;
  end if;
  if p_mode in ('chain', 'names') and n > 1 then
    -- order must be clear: at most the first undated, and no two starting together
    if (select count(*) from jsonb_array_elements(p_rows) x where x ->> 'valid_from' is null) > 1
       or (select count(*) - count(distinct x ->> 'valid_from') from jsonb_array_elements(p_rows) x where x ->> 'valid_from' is not null) > 0 then
      return jsonb_build_array(jsonb_build_object('note', 'concurrent'));
    end if;
  end if;

  for i in 0 .. n - 1 loop
    r := p_rows -> i;
    f := (r ->> 'valid_from')::date; fp := r ->> 'valid_from_precision';
    t := (r ->> 'valid_to')::date; tp := r ->> 'valid_to_precision';
    t0 := t;
    why := '{}';

    -- wholly outside the lifespan: a person has to decide
    if (b is not null and t is not null and internal.tl_before(t, tp, b, bp))
       or (e is not null and f is not null and internal.tl_after(f, fp, e, ep)) then
      out := out || jsonb_build_object('note', 'outside', 'id', r -> 'id', 'label', r ->> 'label',
                                       'before', internal.tl_range(f, fp, t, tp));
      continue;
    end if;

    -- start
    if b is not null and (
         (p_mode = 'fit' or (p_mode = 'chain' and i = 0)) and f is distinct from b
         or (p_mode in ('clamp', 'names') or (p_mode = 'chain' and i > 0)) and (f is null or internal.tl_before(f, fp, b, bp))
         or p_mode = 'clip' and f is not null and internal.tl_before(f, fp, b, bp)) then
      f := b; fp := bp; why := array_append(why, 'start');
    end if;

    -- end
    if p_mode in ('chain', 'names') and i < n - 1 then
      nx := p_rows -> (i + 1);
      -- "until 1949" then "from 1950" is continuous at year precision: only real overlaps and gaps count
      if t is null or internal.tl_starts_after(t, tp, (nx ->> 'valid_from')::date, nx ->> 'valid_from_precision') then
        why := array_append(why, 'overlap');
        t := (nx ->> 'valid_from')::date; tp := nx ->> 'valid_from_precision';
      elsif internal.tl_gap(t, tp, (nx ->> 'valid_from')::date, nx ->> 'valid_from_precision') then
        why := array_append(why, 'gap');
        t := (nx ->> 'valid_from')::date; tp := nx ->> 'valid_from_precision';
      end if;
    elsif p_mode = 'fit' or (p_mode = 'chain' and i = n - 1) then
      if e is not null and t is distinct from e then
        t := e; tp := ep; why := array_append(why, 'end');
      elsif e is null and b is not null and t is not null then
        t := null; why := array_append(why, 'open');
      end if;
    end if;
    if p_mode in ('clamp', 'clip', 'names') and e is not null and (t is null or internal.tl_after(t, tp, e, ep)) then
      t := e; tp := ep; why := array_append(why, 'end');
    end if;

    if f is not null and t is not null and t < f then
      out := out || jsonb_build_object('note', 'outside', 'id', r -> 'id', 'label', r ->> 'label',
                                       'before', internal.tl_range((r ->> 'valid_from')::date, r ->> 'valid_from_precision', t0, r ->> 'valid_to_precision'));
    elsif internal.tl_changed(r, f, fp, t, tp) then
      out := out || jsonb_build_object('id', r -> 'id', 'label', r ->> 'label', 'why', to_jsonb(why),
        'before', internal.tl_range((r ->> 'valid_from')::date, r ->> 'valid_from_precision', t0, r ->> 'valid_to_precision'),
        'after', internal.tl_range(f, fp, t, tp));
    end if;
  end loop;
  return out;
end;
$$;

-- Turn tl_fit() output into plan items for one table/section
create or replace function internal.tl_items(p_fit jsonb, p_table text, p_section text, p_rule text, p_group text default '')
returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(
    case when x ? 'note' then
      jsonb_build_object('key', 'note:' || p_section || ':' || p_group || ':' || coalesce(x ->> 'id', x ->> 'note'), 'op', 'note',
                         'rule', x ->> 'note', 'section', p_section, 'table', p_table, 'id', x -> 'id',
                         'label', coalesce(x ->> 'label', nullif(p_group, '')), 'before', x -> 'before', 'default', false)
    else
      jsonb_build_object('key', p_rule || ':' || (x ->> 'id'), 'op', 'update', 'rule', p_rule, 'section', p_section,
                         'table', p_table, 'id', x -> 'id', 'label', x ->> 'label', 'why', x -> 'why',
                         'before', x -> 'before', 'after', x -> 'after', 'default', true)
    end), '[]'::jsonb)
  from jsonb_array_elements(p_fit) x
$$;

revoke all on function internal.tl_range(date, text, date, text) from public;
revoke all on function internal.tl_changed(jsonb, date, text, date, text) from public;
revoke all on function internal.tl_fit(jsonb, date, text, date, text, text) from public;
revoke all on function internal.tl_before(date, text, date, text) from public;
revoke all on function internal.tl_after(date, text, date, text) from public;
revoke all on function internal.tl_starts_after(date, text, date, text) from public;
revoke all on function internal.tl_gap(date, text, date, text) from public;
revoke all on function internal.tl_items(jsonb, text, text, text, text) from public;

-- -----------------------------------------------------------------------------
-- Plan (read-only). Security definer so it can call the internal helpers; it
-- refuses pages the caller can't see.
-- -----------------------------------------------------------------------------
drop function if exists public.timeline_plan(uuid);
create or replace function public.timeline_plan(p_entity uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  en record;
  term record;
  g record;
  plan jsonb := '[]'::jsonb;
  b date; bp text; e date; ep text;
  physical boolean;
  conditioned boolean;
  rows jsonb;
  w jsonb := '[]'::jsonb;      -- working copy of the conditions
  cur jsonb; nxt jsonb;
  n int; i int; k int;
  n_undated int;
  f date; fp text; t date; tp text;
  why text[];
  v_gone text;
  v_first_gone record;
  role_group text;
  earliest record;
begin
  if public.entity_hidden(p_entity) then
    return plan;
  end if;
  select x.id, x.kind, x.name, x.exists_from, x.exists_from_precision, x.exists_to, x.exists_to_precision,
         x.lifespan_confidence
    into en from public.entities x where x.id = p_entity;
  if not found then
    return plan;
  end if;
  physical := en.kind in ('building', 'site', 'infrastructure', 'street', 'space', 'parcel', 'district', 'water', 'landform');
  conditioned := en.kind in ('building', 'site', 'infrastructure', 'street', 'space');
  if not physical then
    return plan;
  end if;
  b := en.exists_from; bp := en.exists_from_precision;
  e := en.exists_to; ep := en.exists_to_precision;

  -- ===================================================================== lifespan
  -- end it at a recorded demolition
  if e is null then
    select s.valid_from, s.valid_from_precision, ls.label into term
      from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
     where s.entity_id = p_entity and not ls.is_extant and ls.decay_level >= 5 and s.valid_from is not null
       and (b is null or s.valid_from >= b)
     order by s.valid_from limit 1;
    if found then
      e := term.valid_from; ep := term.valid_from_precision;
      plan := plan || jsonb_build_object('key', 'lifespan:end', 'op', 'update', 'rule', 'end_lifespan', 'section', 'lifespan',
        'table', 'entities', 'id', p_entity, 'label', term.label, 'default', true,
        'before', internal.tl_range(b, bp, null, en.exists_to_precision::text), 'after', internal.tl_range(b, bp, e, ep));
    end if;
  end if;
  -- suggest a start from the earliest dated fact (a lower bound, so off by default)
  if b is null then
    select d, p, what into earliest from (
      select s.valid_from d, s.valid_from_precision::text p, 'condition' what from public.entity_states s
        join public.lifecycle_statuses ls on ls.id = s.status
       where s.entity_id = p_entity and s.status not in ('proposed', 'under_construction') and ls.is_extant
      union all select valid_from, valid_from_precision::text, role from public.entity_geometries where entity_id = p_entity and role <> 'viewpoint'
      union all select valid_from, valid_from_precision::text, 'address' from public.addresses where entity_id = p_entity
      union all select valid_from, valid_from_precision::text, 'name' from public.entity_names where entity_id = p_entity and name_type = 'official'
    ) x where d is not null and (e is null or d <= e) order by d limit 1;
    if found then
      plan := plan || jsonb_build_object('key', 'lifespan:start', 'op', 'update', 'rule', 'start_lifespan', 'section', 'lifespan',
        'table', 'entities', 'id', p_entity, 'label', earliest.what, 'default', false,
        'before', internal.tl_range(null, bp, e, ep), 'after', internal.tl_range(earliest.d, earliest.p, e, ep));
    end if;
  end if;

  -- =================================================================== conditions
  if conditioned then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', s.id, 'status', s.status, 'label', ls.label,
             'extant', ls.is_extant, 'gone', (not ls.is_extant and ls.decay_level >= 5),
             'pre', s.status in ('proposed', 'under_construction'),
             'valid_from', s.valid_from, 'valid_from_precision', s.valid_from_precision,
             'valid_to', s.valid_to, 'valid_to_precision', s.valid_to_precision)
             order by s.valid_from nulls first, ls.sort, s.created_at), '[]'::jsonb)
      into rows
      from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
     where s.entity_id = p_entity;
    n := jsonb_array_length(rows);
    n_undated := (select count(*) from jsonb_array_elements(rows) x where x ->> 'valid_from' is null);

    if n = 0 and b is not null then
      -- nothing recorded: in use for its whole life
      plan := plan || jsonb_build_object('key', 'conditions:seed', 'op', 'insert', 'rule', 'seed_active', 'section', 'conditions',
        'table', 'entity_states', 'status', 'active', 'label', 'Active / in use', 'default', true,
        'after', internal.tl_range(b, bp, e, ep));
    elsif n_undated > 1 then
      plan := plan || jsonb_build_object('key', 'note:conditions:undated', 'op', 'note', 'rule', 'undated_conditions',
        'section', 'conditions', 'table', 'entity_states', 'label', n_undated::text, 'default', false);
    elsif n > 0 then
      -- working copy: wf/wt are the proposed range; why collects reasons
      for i in 0 .. n - 1 loop
        cur := rows -> i;
        w := w || jsonb_build_array(cur || jsonb_build_object(
          'wf', cur -> 'valid_from', 'wfp', cur -> 'valid_from_precision',
          'wt', cur -> 'valid_to', 'wtp', cur -> 'valid_to_precision', 'why', '[]'::jsonb, 'drop', false));
      end loop;

      -- an undated condition: "Active" starts with the lifespan, a "gone" one at its end;
      -- anything else (restored, vacant...) happened at some point a person has to find
      cur := w -> 0;
      if cur ->> 'wf' is null then
        if (cur ->> 'gone')::boolean and e is not null then
          w := jsonb_set(w, '{0}', cur || jsonb_build_object('wf', e, 'wfp', ep, 'why', (cur -> 'why') || '"date_at_end"'));
        elsif cur ->> 'status' = 'active' and b is not null then
          w := jsonb_set(w, '{0}', cur || jsonb_build_object('wf', b, 'wfp', bp, 'why', (cur -> 'why') || '"date_at_start"'));
        elsif not (cur ->> 'pre')::boolean then
          w := jsonb_set(w, '{0}', cur || '{"drop": true}');
          plan := plan || jsonb_build_object('key', 'note:conditions:undated:' || (cur ->> 'id'), 'op', 'note', 'rule', 'undated_condition',
            'section', 'conditions', 'table', 'entity_states', 'id', cur -> 'id', 'label', cur ->> 'label', 'default', false);
        end if;
      end if;

      -- the same condition twice in a row: keep the first, it runs on
      k := null;
      for i in 0 .. n - 1 loop
        nxt := w -> i;
        continue when (nxt ->> 'drop')::boolean;
        if k is null then
          k := i;
          continue;
        end if;
        cur := w -> k;
        if nxt ->> 'status' = cur ->> 'status' then
          w := jsonb_set(w, array[i::text], nxt || '{"drop": true}');
          plan := plan || jsonb_build_object('key', 'merge:' || (nxt ->> 'id'), 'op', 'delete', 'rule', 'merge_duplicate',
            'section', 'conditions', 'table', 'entity_states', 'id', nxt -> 'id', 'label', nxt ->> 'label', 'default', true,
            'before', internal.tl_range((nxt ->> 'valid_from')::date, nxt ->> 'valid_from_precision',
                                        (nxt ->> 'valid_to')::date, nxt ->> 'valid_to_precision'));
          if cur ->> 'wt' is not null and (nxt ->> 'wt' is null or (nxt ->> 'wt')::date > (cur ->> 'wt')::date) then
            w := jsonb_set(w, array[k::text], cur || jsonb_build_object('wt', nxt -> 'wt', 'wtp', nxt -> 'wtp',
                                                                       'why', (cur -> 'why') || '"merge_duplicate"'));
          end if;
        else
          k := i;
        end if;
      end loop;

      -- nothing standing before the lifespan starts (proposed / under construction may)
      if b is not null then
        for i in 0 .. n - 1 loop
          cur := w -> i;
          if not (cur ->> 'drop')::boolean and not (cur ->> 'pre')::boolean and not (cur ->> 'gone')::boolean
             and cur ->> 'wf' is not null and (cur ->> 'wf')::date < b
             and (cur ->> 'wt' is null or (cur ->> 'wt')::date > b) then
            w := jsonb_set(w, array[i::text], cur || jsonb_build_object('wf', b, 'wfp', bp, 'why', (cur -> 'why') || '"clamp_start"'));
          end if;
        end loop;
      end if;

      -- in use from the start until the first recorded condition (e.g. before abandonment)
      if b is not null then
        k := null;
        for i in 0 .. n - 1 loop
          cur := w -> i;
          if not (cur ->> 'drop')::boolean and not (cur ->> 'pre')::boolean then
            k := i;
            exit;
          end if;
        end loop;
        if k is not null then
          cur := w -> k;
          if cur ->> 'wf' is not null and (cur ->> 'wf')::date > b then
            if cur ->> 'status' = 'active' then
              w := jsonb_set(w, array[k::text], cur || jsonb_build_object('wf', b, 'wfp', bp, 'why', (cur -> 'why') || '"extend_back"'));
            else
              plan := plan || jsonb_build_object('key', 'conditions:fill', 'op', 'insert', 'rule', 'fill_active',
                'section', 'conditions', 'table', 'entity_states', 'status', 'active', 'label', 'Active / in use',
                'next', cur ->> 'label', 'default', true,
                'after', internal.tl_range(b, bp, (cur ->> 'wf')::date, cur ->> 'wfp'));
            end if;
          end if;
        end if;
      end if;

      -- standing conditions recorded after the lifespan ends: set aside (deleting them is a suggestion)
      if e is not null then
        for i in 0 .. n - 1 loop
          cur := w -> i;
          continue when (cur ->> 'drop')::boolean or not (cur ->> 'extant')::boolean;
          if cur ->> 'wf' is not null and (cur ->> 'wf')::date > e then
            w := jsonb_set(w, array[i::text], cur || '{"drop": true}');
            plan := plan || jsonb_build_object('key', 'after_end:' || (cur ->> 'id'), 'op', 'delete', 'rule', 'after_end',
              'section', 'conditions', 'table', 'entity_states', 'id', cur -> 'id', 'label', cur ->> 'label', 'default', false,
              'before', internal.tl_range((cur ->> 'valid_from')::date, cur ->> 'valid_from_precision',
                                          (cur ->> 'valid_to')::date, cur ->> 'valid_to_precision'));
          end if;
        end loop;
      end if;

      -- one chain: each condition runs until the next one starts
      k := null;
      for i in 0 .. n - 1 loop
        cur := w -> i;
        continue when (cur ->> 'drop')::boolean;
        if k is not null then
          nxt := cur;
          cur := w -> k;
          if nxt ->> 'wf' is not null then
            if cur ->> 'wt' is null or internal.tl_starts_after((cur ->> 'wt')::date, cur ->> 'wtp', (nxt ->> 'wf')::date, nxt ->> 'wfp') then
              w := jsonb_set(w, array[k::text], cur || jsonb_build_object('wt', nxt -> 'wf', 'wtp', nxt -> 'wfp',
                'next', nxt ->> 'label', 'why', (cur -> 'why') || '"close_overlap"'));
            elsif internal.tl_gap((cur ->> 'wt')::date, cur ->> 'wtp', (nxt ->> 'wf')::date, nxt ->> 'wfp') and not (cur ->> 'gone')::boolean then
              w := jsonb_set(w, array[k::text], cur || jsonb_build_object('wt', nxt -> 'wf', 'wtp', nxt -> 'wfp',
                'next', nxt ->> 'label', 'why', (cur -> 'why') || '"close_gap"'));
            end if;
          end if;
        end if;
        k := i;
      end loop;

      -- nothing standing after the lifespan ends
      if e is not null then
        for i in 0 .. n - 1 loop
          cur := w -> i;
          continue when (cur ->> 'drop')::boolean or not (cur ->> 'extant')::boolean;
          if (cur ->> 'wf' is null or (cur ->> 'wf')::date <= e) and (cur ->> 'wt' is null or (cur ->> 'wt')::date > e) then
            w := jsonb_set(w, array[i::text], cur || jsonb_build_object('wt', e, 'wtp', ep, 'why', (cur -> 'why') || '"close_at_end"'));
          end if;
        end loop;
      end if;

      -- emit the edited conditions
      for i in 0 .. n - 1 loop
        cur := w -> i;
        continue when (cur ->> 'drop')::boolean;
        f := (cur ->> 'wf')::date; fp := cur ->> 'wfp'; t := (cur ->> 'wt')::date; tp := cur ->> 'wtp';
        if f is not null and t is not null and t < f then
          plan := plan || jsonb_build_object('key', 'note:conditions:' || (cur ->> 'id'), 'op', 'note', 'rule', 'outside',
            'section', 'conditions', 'table', 'entity_states', 'id', cur -> 'id', 'label', cur ->> 'label', 'default', false,
            'before', internal.tl_range((cur ->> 'valid_from')::date, cur ->> 'valid_from_precision', (cur ->> 'valid_to')::date, cur ->> 'valid_to_precision'));
        elsif internal.tl_changed(cur, f, fp, t, tp) then
          plan := plan || jsonb_build_object('key', 'condition:' || (cur ->> 'id'), 'op', 'update',
            'rule', cur -> 'why' ->> 0, 'why', cur -> 'why', 'section', 'conditions', 'table', 'entity_states',
            'id', cur -> 'id', 'label', cur ->> 'label', 'next', cur ->> 'next', 'default', true,
            'before', internal.tl_range((cur ->> 'valid_from')::date, cur ->> 'valid_from_precision', (cur ->> 'valid_to')::date, cur ->> 'valid_to_precision'),
            'after', internal.tl_range(f, fp, t, tp));
        elsif e is null and t is not null and (cur ->> 'extant')::boolean
              and not exists (select 1 from jsonb_array_elements(w) y
                               where not (y ->> 'drop')::boolean and (y ->> 'wf')::date >= t and y ->> 'id' <> cur ->> 'id') then
          -- the last thing we know ended, and nothing says what came next: maybe it's still so (a guess)
          plan := plan || jsonb_build_object('key', 'open:' || (cur ->> 'id'), 'op', 'update', 'rule', 'extend_open',
            'why', '["open"]'::jsonb, 'section', 'conditions', 'table', 'entity_states',
            'id', cur -> 'id', 'label', cur ->> 'label', 'default', false,
            'before', internal.tl_range(f, fp, t, tp), 'after', internal.tl_range(f, fp, null, tp));
        end if;
      end loop;
    end if;

    -- a recorded demolition that disagrees with the lifespan end (which is right is for a person to say)
    if en.exists_to is not null then
      select s.valid_from, s.valid_from_precision, ls.label into v_first_gone
        from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
       where s.entity_id = p_entity and not ls.is_extant and ls.decay_level >= 5 and s.valid_from is not null
       order by s.valid_from limit 1;
      if found and extract(year from v_first_gone.valid_from) <> extract(year from en.exists_to) then
        plan := plan || jsonb_build_object('key', 'lifespan:gone', 'op', 'update', 'rule', 'gone_mismatch', 'section', 'lifespan',
          'table', 'entities', 'id', p_entity, 'label', v_first_gone.label, 'default', false,
          'before', internal.tl_range(b, bp, en.exists_to, en.exists_to_precision::text),
          'after', internal.tl_range(b, bp, v_first_gone.valid_from, v_first_gone.valid_from_precision::text));
      end if;
    end if;

    -- the lifespan ends but no condition says how
    if e is not null and en.kind in ('building', 'infrastructure', 'street')
       and not exists (select 1 from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
                        where s.entity_id = p_entity and not ls.is_extant and ls.decay_level >= 5) then
      v_gone := case when en.kind = 'street' then 'vacated' else 'demolished' end;
      if exists (select 1 from public.lifecycle_statuses where id = v_gone) then
        plan := plan || jsonb_build_object('key', 'conditions:gone', 'op', 'insert', 'rule', 'add_gone', 'section', 'conditions',
          'table', 'entity_states', 'status', v_gone, 'label', (select label from public.lifecycle_statuses where id = v_gone),
          'default', true, 'after', internal.tl_range(e, ep, null, ep));
      end if;
    end if;
  end if;

  -- ======================================================================= shapes
  for role_group in select unnest(array['area', 'point', 'centerline', 'boundary']) loop
    select coalesce(jsonb_agg(jsonb_build_object('id', gg.id, 'label', gg.role,
             'valid_from', gg.valid_from, 'valid_from_precision', gg.valid_from_precision,
             'valid_to', gg.valid_to, 'valid_to_precision', gg.valid_to_precision)
             order by gg.valid_from nulls first, gg.created_at), '[]'::jsonb)
      into rows
      from public.entity_geometries gg
     where gg.entity_id = p_entity
       and case role_group
             when 'area' then gg.role in ('footprint', 'shape') and st_dimension(gg.geom) = 2
             when 'point' then gg.role = 'point'
             else gg.role = role_group
           end;
    plan := plan || internal.tl_items(
      internal.tl_fit(rows, b, bp, e, ep, case when jsonb_array_length(rows) = 1 then 'fit' else 'chain' end),
      'entity_geometries', 'shapes', 'fit_shape', role_group);
  end loop;

  -- ==================================================================== addresses
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id,
           'label', coalesce(case when s.id is not null then nullif(trim(concat_ws(' ', a.house_number, s.name, a.unit)), '') end,
                             a.raw_address, nullif(trim(concat_ws(' ', a.house_number, a.unit)), ''), 'address'),
           'valid_from', a.valid_from, 'valid_from_precision', a.valid_from_precision,
           'valid_to', a.valid_to, 'valid_to_precision', a.valid_to_precision)
           order by a.valid_from nulls first, a.created_at), '[]'::jsonb)
    into rows
    from public.addresses a left join public.entities s on s.id = a.street_id
   where a.entity_id = p_entity;
  plan := plan || internal.tl_items(
    internal.tl_fit(rows, b, bp, e, ep, case when jsonb_array_length(rows) = 1 then 'fit' else 'clamp' end),
    'addresses', 'addresses', 'fit_address');

  -- ======================================================================== names
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'label', x.name,
           'valid_from', x.valid_from, 'valid_from_precision', x.valid_from_precision,
           'valid_to', x.valid_to, 'valid_to_precision', x.valid_to_precision)
           order by x.valid_from nulls first, x.created_at), '[]'::jsonb)
    into rows
    from public.entity_names x where x.entity_id = p_entity and x.name_type = 'official';
  if jsonb_array_length(rows) > 1 then
    plan := plan || internal.tl_items(internal.tl_fit(rows, b, bp, e, ep, 'names'), 'entity_names', 'names', 'fit_name');
  end if;
  -- other dated names (and a single official one) are only clipped
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'label', x.name,
           'valid_from', x.valid_from, 'valid_from_precision', x.valid_from_precision,
           'valid_to', x.valid_to, 'valid_to_precision', x.valid_to_precision)), '[]'::jsonb)
    into rows
    from public.entity_names x
   where x.entity_id = p_entity and (x.valid_from is not null or x.valid_to is not null)
     and (x.name_type <> 'official' or (select count(*) from public.entity_names y where y.entity_id = p_entity and y.name_type = 'official') = 1);
  plan := plan || internal.tl_items(internal.tl_fit(rows, b, bp, e, ep, 'clamp'), 'entity_names', 'names', 'fit_name');

  -- ================================================================== dated facts
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'label', coalesce(k2.label, a.key) || ': ' || (a.value #>> '{}'),
           'valid_from', a.valid_from, 'valid_from_precision', a.valid_from_precision,
           'valid_to', a.valid_to, 'valid_to_precision', a.valid_to_precision)), '[]'::jsonb)
    into rows
    from public.entity_attributes a left join public.attribute_keys k2 on k2.id = a.key
   where a.entity_id = p_entity and (a.valid_from is not null or a.valid_to is not null);
  plan := plan || internal.tl_items(internal.tl_fit(rows, b, bp, e, ep, 'clamp'), 'entity_attributes', 'facts', 'fit_fact');

  -- ==================================================================== relations
  -- tenants / owners of this place, and where this place is: within both lifespans
  for g in
    select r.id, r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision,
           o.name as other, case when r.subject_id = p_entity then rt.label else rt.inverse_label end as reading,
           o.exists_from as o_from, o.exists_from_precision::text as o_fp, o.exists_to as o_to, o.exists_to_precision::text as o_tp
      from public.relations r
      join public.relation_types rt on rt.id = r.predicate
      join public.entities o on o.id = case when r.subject_id = p_entity then r.object_id else r.subject_id end
     where (r.object_id = p_entity and r.predicate in ('occupies', 'resides_at', 'owns', 'part_of'))
        or (r.subject_id = p_entity and r.predicate in ('located_on', 'located_in', 'part_of'))
  loop
    plan := plan || internal.tl_items(
      internal.tl_fit(
        jsonb_build_array(jsonb_build_object('id', g.id, 'label', g.reading || ' ' || g.other,
          'valid_from', g.valid_from, 'valid_from_precision', g.valid_from_precision,
          'valid_to', g.valid_to, 'valid_to_precision', g.valid_to_precision)),
        case when g.o_from is not null and (b is null or g.o_from > b) then g.o_from else b end,
        case when g.o_from is not null and (b is null or g.o_from > b) then g.o_fp else bp end,
        case when g.o_to is not null and (e is null or g.o_to < e) then g.o_to else e end,
        case when g.o_to is not null and (e is null or g.o_to < e) then g.o_tp else ep end,
        'clip'),
      'relations', 'relations', 'fit_relation');
  end loop;

  -- ======================================================================= spaces
  -- storefronts, suites and halls inside a building end with it
  if en.kind in ('building', 'site') then
    select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'label', s.name,
             'valid_from', s.exists_from, 'valid_from_precision', s.exists_from_precision,
             'valid_to', s.exists_to, 'valid_to_precision', s.exists_to_precision)), '[]'::jsonb)
      into rows
      from public.relations r join public.entities s on s.id = r.subject_id
     where r.object_id = p_entity and r.predicate = 'part_of' and s.kind = 'space';
    plan := plan || internal.tl_items(internal.tl_fit(rows, b, bp, e, ep, 'clamp'), 'entities', 'spaces', 'fit_space');
  end if;

  return plan;
end;
$$;

comment on function public.timeline_plan(uuid) is
  'Proposed timeline fixes for one page (read-only). Items: key, op (update|insert|delete|note), rule, section, table, id, label, before, after, default.';

-- -----------------------------------------------------------------------------
-- Apply. Re-plans inside the transaction and applies the items whose key was
-- chosen (p_keys null = every item that is on by default).
-- -----------------------------------------------------------------------------
drop function if exists public.normalize_timeline(uuid, text[]);
create or replace function public.normalize_timeline(p_entity uuid, p_keys text[] default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  it jsonb;
  a jsonb;
  v_conf public.confidence_level;
  v_done int := 0;
  v_plan jsonb;
begin
  if not public.has_permission('clean_timelines') then
    raise exception 'You need the “Clean up timelines” permission' using errcode = '42501';
  end if;
  select lifespan_confidence into v_conf from public.entities where id = p_entity;
  if not found or public.entity_hidden(p_entity) then
    raise exception 'Page not found' using errcode = 'P0002';
  end if;

  v_plan := public.timeline_plan(p_entity);
  -- lifespan first, then removals, then edits, then additions
  for it in
    select x from jsonb_array_elements(v_plan) x
     where x ->> 'op' <> 'note'
       and (case when p_keys is null then (x ->> 'default')::boolean else (x ->> 'key') = any (p_keys) end)
     order by case when x ->> 'table' = 'entities' and x ->> 'id' = p_entity::text then 0
                   when x ->> 'op' = 'delete' then 1 when x ->> 'op' = 'update' then 2 else 3 end
  loop
    a := it -> 'after';
    if it ->> 'op' = 'delete' and it ->> 'table' = 'entity_states' then
      delete from public.entity_states where id = (it ->> 'id')::uuid and entity_id = p_entity;
    elsif it ->> 'op' = 'insert' and it ->> 'table' = 'entity_states' then
      insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, note)
      values (p_entity, it ->> 'status',
              (a ->> 'valid_from')::date, (a ->> 'valid_from_precision')::public.date_precision,
              (a ->> 'valid_to')::date, coalesce((a ->> 'valid_to_precision')::public.date_precision, 'year'),
              case when it ->> 'rule' = 'add_gone' then v_conf else 'approximate' end,
              case it ->> 'rule'
                when 'add_gone' then 'Added by timeline cleanup: the lifespan ends here.'
                else 'Added by timeline cleanup: assumed in use until the next recorded condition.' end);
    elsif it ->> 'op' = 'update' and it ->> 'table' = 'entities' then
      -- this page's lifespan (each fix sets only its own end), or a space inside it
      update public.entities
         set exists_from = case when it ->> 'rule' in ('end_lifespan', 'gone_mismatch') then exists_from else (a ->> 'valid_from')::date end,
             exists_from_precision = case when it ->> 'rule' in ('end_lifespan', 'gone_mismatch') then exists_from_precision
                                          else (a ->> 'valid_from_precision')::public.date_precision end,
             exists_to = case when it ->> 'rule' = 'start_lifespan' then exists_to else (a ->> 'valid_to')::date end,
             exists_to_precision = case when it ->> 'rule' = 'start_lifespan' then exists_to_precision
                                        else (a ->> 'valid_to_precision')::public.date_precision end
       where id = (it ->> 'id')::uuid
         and (id = p_entity or exists (select 1 from public.relations r
                                        where r.subject_id = (it ->> 'id')::uuid and r.object_id = p_entity and r.predicate = 'part_of'));
    elsif it ->> 'op' = 'update' and it ->> 'table' in ('entity_states', 'entity_geometries', 'addresses', 'entity_names', 'entity_attributes') then
      execute format('update public.%I set valid_from = $1, valid_from_precision = $2, valid_to = $3, valid_to_precision = $4
                       where id = $5 and entity_id = $6', it ->> 'table')
        using (a ->> 'valid_from')::date, (a ->> 'valid_from_precision')::public.date_precision,
              (a ->> 'valid_to')::date, (a ->> 'valid_to_precision')::public.date_precision,
              (it ->> 'id')::uuid, p_entity;
    elsif it ->> 'op' = 'update' and it ->> 'table' = 'relations' then
      update public.relations
         set valid_from = (a ->> 'valid_from')::date, valid_from_precision = (a ->> 'valid_from_precision')::public.date_precision,
             valid_to = (a ->> 'valid_to')::date, valid_to_precision = (a ->> 'valid_to_precision')::public.date_precision
       where id = (it ->> 'id')::uuid and (subject_id = p_entity or object_id = p_entity);
    else
      continue;
    end if;
    v_done := v_done + 1;
  end loop;

  v_plan := public.timeline_plan(p_entity);
  return jsonb_build_object(
    'applied', v_done,
    'remaining', (select count(*) from jsonb_array_elements(v_plan) x where x ->> 'op' <> 'note' and (x ->> 'default')::boolean));
end;
$$;

-- -----------------------------------------------------------------------------
-- Pages with something to fix (for the admin list)
-- -----------------------------------------------------------------------------
drop function if exists public.timeline_review(int);
create or replace function public.timeline_review(p_limit int default 300)
returns table (entity_id uuid, slug text, name text, kind text, fixes int, suggestions int, notes int, sections text[])
language sql stable security invoker set search_path = public as $$
  select e.id, e.slug, e.name, e.kind,
         (select count(*)::int from jsonb_array_elements(p.plan) x where x ->> 'op' <> 'note' and (x ->> 'default')::boolean),
         (select count(*)::int from jsonb_array_elements(p.plan) x where x ->> 'op' <> 'note' and not (x ->> 'default')::boolean),
         (select count(*)::int from jsonb_array_elements(p.plan) x where x ->> 'op' = 'note'),
         array(select distinct x ->> 'section' from jsonb_array_elements(p.plan) x order by 1)
    from public.entities e
    cross join lateral (select public.timeline_plan(e.id) as plan) p
   where public.has_permission('clean_timelines')
     and e.kind in ('building', 'site', 'infrastructure', 'street', 'space', 'parcel', 'district', 'water', 'landform')
     and jsonb_array_length(p.plan) > 0
   order by 5 desc, 6 desc, e.name
   limit greatest(1, least(coalesce(p_limit, 300), 2000))
$$;

-- Signed-in only (the functions also check the permission themselves)
revoke execute on function public.timeline_plan(uuid) from public, anon;
revoke execute on function public.normalize_timeline(uuid, text[]) from public, anon;
revoke execute on function public.timeline_review(int) from public, anon;
grant execute on function public.timeline_plan(uuid) to authenticated;
grant execute on function public.normalize_timeline(uuid, text[]) to authenticated;
grant execute on function public.timeline_review(int) to authenticated;
