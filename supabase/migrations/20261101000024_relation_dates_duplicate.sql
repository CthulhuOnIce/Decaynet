-- =============================================================================
-- Decaynet :: 0024 relation dates and plain duplicates
--
-- Timeline cleanup, relations:
--   * occupancy (occupied by, lived at), also of the building's storefronts and
--     suites, ends when the place stops being in use: the first vacant, closed,
--     abandoned, ruined or demolished condition after it began (when its start
--     is unknown: when the place went out of use for good)
--   * "designed by" / "built by" left open end at construction
--   * an undated occupancy or ownership can start with the place (a suggestion,
--     off by default)
--   * each relation item names the ends it changes ("sets"), so a fix and a
--     suggestion on the same link can be applied separately
-- Timeline cleanup, conditions: a note when something new is recorded after the
--   place was gone ("Demolished" 1950, then "Under construction" 1958): two
--   buildings in one page, which the plain duplicate below separates.
--
-- duplicate_as_kind() accepts the page's own kind: an exact copy (everything
-- but external ids), for splitting a page that holds two things.
-- =============================================================================

-- Timeline plan (as in 0019, plus the relation rules and the rebuilt note)
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
  rb record;
  u record;
  lb date; lbp text; ub date; ubp text;
  nf date; nfp text; nt date; ntp text;
  rwhy text[];
  rsets text[];
  v_use text;
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

    -- rebuilt: a working structure recorded after it was gone (two buildings in one page)
    select g1.valid_from, g1.valid_from_precision::text as fp, l1.label as gone, l2.label as later, s2.valid_from as later_from
      into rb
      from public.entity_states g1
      join public.lifecycle_statuses l1 on l1.id = g1.status
      join public.entity_states s2 on s2.entity_id = g1.entity_id and s2.valid_from > g1.valid_from
      join public.lifecycle_statuses l2 on l2.id = s2.status
     where g1.entity_id = p_entity and not l1.is_extant and l1.decay_level >= 5 and g1.valid_from is not null
       and l2.is_extant and l2.decay_level = 0   -- under construction, in use, restored, repurposed
     order by g1.valid_from, s2.valid_from
     limit 1;
    if found then
      plan := plan || jsonb_build_object('key', 'note:conditions:rebuilt', 'op', 'note', 'rule', 'rebuilt', 'section', 'conditions',
        'table', 'entity_states', 'label', rb.gone, 'next', rb.later, 'default', false,
        'before', internal.tl_range(rb.valid_from, rb.fp, rb.later_from, 'year'));
      -- split the page first: ending the lifespan now would end the copy too
      select jsonb_agg(case when x ->> 'rule' = 'end_lifespan' then x || '{"default": false}'::jsonb else x end order by t.ord)
        into plan from jsonb_array_elements(plan) with ordinality t(x, ord);
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
  -- Links of this place (and of its storefronts and suites):
  --   tenants, owners, "part of", "is on" … stay within both sides' lifespans
  --   occupancy (occupied by, lived at) ends when the place stops being in use:
  --     the first vacant / closed / abandoned / ruined / demolished condition after
  --     it began (or, when its start is unknown, when it went out of use for good)
  --   "designed by" / "built by" left open end at construction (the lifespan start)
  --   an undated occupancy or ownership can start with the place (a suggestion)
  for g in
    select r.id, r.predicate, r.valid_from, r.valid_from_precision::text as fp, r.valid_to, r.valid_to_precision::text as tp,
           case when r.subject_id = p_entity then rt.label else rt.inverse_label end || ' ' || o.name
             || coalesce(' (in ' || sp.name || ')', '') as label,
           o.exists_from as o_from, o.exists_from_precision::text as o_fp, o.exists_to as o_to, o.exists_to_precision::text as o_tp
      from public.relations r
      join public.relation_types rt on rt.id = r.predicate
      join public.entities o on o.id = case when r.subject_id = p_entity then r.object_id else r.subject_id end
      left join public.entities sp on sp.id = r.object_id and r.object_id <> p_entity and r.subject_id <> p_entity
     where (r.object_id = p_entity and r.predicate in ('occupies', 'resides_at', 'owns', 'part_of'))
        or (r.subject_id = p_entity and r.predicate in ('located_on', 'located_in', 'part_of', 'intersects', 'designed_by', 'built_by'))
        or (r.predicate in ('occupies', 'resides_at')
            and r.object_id in (select x.subject_id from public.relations x join public.entities s on s.id = x.subject_id
                                 where x.object_id = p_entity and x.predicate = 'part_of' and s.kind = 'space'))
     order by r.predicate, r.valid_from nulls first
  loop
    nf := g.valid_from; nfp := g.fp; nt := g.valid_to; ntp := g.tp;
    rwhy := '{}'; rsets := '{}'; v_use := null;

    if g.predicate in ('designed_by', 'built_by') then
      -- design and construction end when it's built
      if g.valid_to is null and b is not null and (g.valid_from is null or g.valid_from <= b) then
        nt := b; ntp := bp; rwhy := array_append(rwhy, 'construction'); rsets := array_append(rsets, 'end');
      end if;
      lb := null;
    else
      -- within both lifespans
      lb := case when g.o_from is not null and (b is null or g.o_from > b) then g.o_from else b end;
      lbp := case when g.o_from is not null and (b is null or g.o_from > b) then g.o_fp else bp end;
      ub := case when g.o_to is not null and (e is null or g.o_to < e) then g.o_to else e end;
      ubp := case when g.o_to is not null and (e is null or g.o_to < e) then g.o_tp else ep end;
      if (lb is not null and g.valid_to is not null and internal.tl_before(g.valid_to, g.tp, lb, lbp))
         or (ub is not null and g.valid_from is not null and internal.tl_after(g.valid_from, g.fp, ub, ubp)) then
        plan := plan || jsonb_build_object('key', 'note:relations:' || g.id, 'op', 'note', 'rule', 'outside', 'section', 'relations',
          'table', 'relations', 'id', g.id, 'label', g.label, 'default', false,
          'before', internal.tl_range(g.valid_from, g.fp, g.valid_to, g.tp));
        continue;
      end if;
      if g.valid_from is not null and lb is not null and internal.tl_before(g.valid_from, g.fp, lb, lbp) then
        nf := lb; nfp := lbp; rwhy := array_append(rwhy, 'start'); rsets := array_append(rsets, 'start');
      end if;
      if ub is not null and (g.valid_to is null or internal.tl_after(g.valid_to, g.tp, ub, ubp)) then
        nt := ub; ntp := ubp; rwhy := array_append(rwhy, 'end'); rsets := array_append(rsets, 'end');
      end if;

      -- occupancy ends when the place stops being in use
      if g.predicate in ('occupies', 'resides_at') then
        select s.valid_from, s.valid_from_precision::text as fp, ls.label into u
          from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
         where s.entity_id = p_entity and s.valid_from is not null
           and not (ls.is_extant and ls.decay_level <= 1) and s.status not in ('proposed', 'under_construction')
           and case when g.valid_from is not null then s.valid_from > g.valid_from
                    else not exists (select 1 from public.entity_states s2 join public.lifecycle_statuses l2 on l2.id = s2.status
                                      where s2.entity_id = p_entity and s2.valid_from > s.valid_from
                                        and l2.is_extant and l2.decay_level <= 1
                                        and s2.status not in ('proposed', 'under_construction'))
               end
         order by s.valid_from
         limit 1;
        if found and (nt is null or nt > u.valid_from) then
          nt := u.valid_from; ntp := u.fp; v_use := u.label;
          rwhy := array_append(array_remove(rwhy, 'end'), 'end_of_use');
          if not ('end' = any (rsets)) then rsets := array_append(rsets, 'end'); end if;
        end if;
      end if;
    end if;

    if nf is not null and nt is not null and nt < nf then
      plan := plan || jsonb_build_object('key', 'note:relations:' || g.id, 'op', 'note', 'rule', 'outside', 'section', 'relations',
        'table', 'relations', 'id', g.id, 'label', g.label, 'default', false,
        'before', internal.tl_range(g.valid_from, g.fp, g.valid_to, g.tp));
      continue;
    end if;
    if cardinality(rsets) > 0 then
      plan := plan || jsonb_build_object('key', 'fit_relation:' || g.id, 'op', 'update',
        'rule', case when 'end_of_use' = any (rwhy) then 'end_with_use' when 'construction' = any (rwhy) then 'end_at_construction'
                     else 'fit_relation' end,
        'why', to_jsonb(rwhy), 'sets', to_jsonb(rsets), 'use', v_use,
        'section', 'relations', 'table', 'relations', 'id', g.id, 'label', g.label, 'default', true,
        'before', internal.tl_range(g.valid_from, g.fp, g.valid_to, g.tp),
        'after', internal.tl_range(nf, nfp, nt, ntp));
    end if;
    -- an undated occupancy or ownership could start when the place was built (a suggestion:
    -- often it was later); undated "is on" / "part of" links just mean "always"
    if g.valid_from is null and lb is not null and g.predicate in ('occupies', 'resides_at', 'owns') then
      plan := plan || jsonb_build_object('key', 'start_relation:' || g.id, 'op', 'update', 'rule', 'start_with_place',
        'sets', '["start"]'::jsonb, 'section', 'relations', 'table', 'relations', 'id', g.id, 'label', g.label, 'default', false,
        'before', internal.tl_range(g.valid_from, g.fp, g.valid_to, g.tp),
        'after', internal.tl_range(lb, lbp, nt, ntp));
    end if;
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


-- Apply (as in 0019; relation items set only their own ends, and reach storefront tenants)
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
      -- only the end(s) this item is about ("sets"), so a fix and a suggestion on one link don't overwrite each other
      update public.relations
         set valid_from = case when coalesce(it -> 'sets' ? 'start', true) then (a ->> 'valid_from')::date else valid_from end,
             valid_from_precision = case when coalesce(it -> 'sets' ? 'start', true)
                                         then (a ->> 'valid_from_precision')::public.date_precision else valid_from_precision end,
             valid_to = case when coalesce(it -> 'sets' ? 'end', true) then (a ->> 'valid_to')::date else valid_to end,
             valid_to_precision = case when coalesce(it -> 'sets' ? 'end', true)
                                       then (a ->> 'valid_to_precision')::public.date_precision else valid_to_precision end
       where id = (it ->> 'id')::uuid
         and (subject_id = p_entity or object_id = p_entity
              -- tenants of this building's storefronts and suites
              or object_id in (select x.subject_id from public.relations x
                                where x.object_id = p_entity and x.predicate = 'part_of'));
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


-- Duplicate: the same kind is an exact copy (otherwise as in 0020)
create or replace function public.duplicate_as_kind_preview(p_entity uuid, p_kind text)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  e record;
  v_tie record;
begin
  if public.entity_hidden(p_entity) then
    return null;
  end if;
  select x.id, x.kind, x.name, k.label into e
    from public.entities x join public.entity_kinds k on k.id = x.kind where x.id = p_entity;
  if not found then
    return null;
  end if;
  if not exists (select 1 from public.entity_kinds where id = p_kind) then
    return jsonb_build_object('blocked', 'Unknown kind.');
  end if;
  if 'media' in (p_kind, e.kind) then
    return jsonb_build_object('blocked', 'Media pages hold a file, so they can''t be duplicated. Upload the file again instead.');
  end if;
  select * into v_tie from internal.ck_tie(e.kind, p_kind);

  return jsonb_build_object(
    'from', e.kind, 'from_label', e.label,
    'to', p_kind, 'to_label', (select label from public.entity_kinds where id = p_kind),
    'same', p_kind = e.kind,
    'name', case when p_kind = e.kind then e.name || ' (copy)' else e.name end,
    'article', coalesce((select length(body) > 0 from public.articles where entity_id = p_entity), false),
    'sources', (select count(*) from public.sources where entity_id = p_entity),
    'tie', case when v_tie.predicate is not null then jsonb_build_object(
             'reading', (select label from public.relation_types where id = v_tie.predicate),
             'copy_is_subject', v_tie.copy_is_subject) end,
    'event', p_kind = 'event',
    'copied', (select coalesce(jsonb_agg(jsonb_build_object('what', what, 'label', label) order by what, label), '[]'::jsonb)
                 from internal.ck_plan(p_entity, p_kind) where copy),
    'left', (select coalesce(jsonb_agg(jsonb_build_object('what', what, 'label', label, 'why', why) order by why, what, label), '[]'::jsonb)
               from internal.ck_plan(p_entity, p_kind) where not copy));
end;
$$;


create or replace function public.duplicate_as_kind(p_entity uuid, p_kind text, p_name text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  e record;
  v_new uuid;
  v_slug text;
  v_name text;
  v_map jsonb := '{}'::jsonb;   -- original page source id -> copy
  s record;
  v_sid uuid;
  t text;
  v_cols text;
  v_body text;
  v_tie record;
  v_copied int := 0;
  n int;
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or public.entity_hidden(p_entity) then
    raise exception 'Page not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.entity_kinds where id = p_kind) then
    raise exception 'Unknown kind “%”', p_kind using errcode = '22023';
  end if;
  if 'media' in (p_kind, e.kind) then
    raise exception 'Media pages can''t be duplicated' using errcode = '22023';
  end if;

  -- the new page
  v_name := coalesce(nullif(trim(p_name), ''), case when p_kind = e.kind then e.name || ' (copy)' else e.name end);
  v_slug := left(coalesce(nullif(trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g')), ''), p_kind), 70);
  if exists (select 1 from public.entities where slug = v_slug) then
    v_slug := left(v_slug, 60) || '-' || case when p_kind = e.kind then 'copy' else p_kind end;
  end if;
  if exists (select 1 from public.entities where slug = v_slug) then
    v_slug := v_slug || '-' || substr(md5(random()::text), 1, 5);
  end if;
  insert into public.entities (kind, slug, name, summary, exists_from, exists_from_precision, exists_to, exists_to_precision,
                               lifespan_confidence, is_private, created_by)
  values (p_kind, v_slug, v_name, e.summary, e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision,
          e.lifespan_confidence, e.is_private, auth.uid())
  returning id into v_new;
  if p_kind = 'event' then
    insert into public.event_details (entity_id, event_type)
    values (v_new, coalesce((select event_type from public.event_details where entity_id = p_entity),
                            (select id from public.event_types where id = 'other'),
                            (select id from public.event_types order by sort limit 1)));
  end if;

  -- the original's own sources, so deleting it later can't take the citations along
  for s in select * from public.sources where entity_id = p_entity loop
    insert into public.sources (title, kind, author, publisher, published_on, published_precision, url, archive_url,
                                repository, call_number, notes, entity_id, created_by)
    values (s.title, s.kind, s.author, s.publisher, s.published_on, s.published_precision, s.url, s.archive_url,
            s.repository, s.call_number, s.notes, v_new, auth.uid())
    returning id into v_sid;
    v_map := v_map || jsonb_build_object(s.id::text, v_sid);
  end loop;

  -- facts kept on the page itself
  foreach t in array array['entity_names', 'entity_tags', 'entity_attributes', 'entity_geometries', 'addresses', 'entity_states'] loop
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
      from information_schema.columns
     where table_schema = 'public' and table_name = t and is_generated = 'NEVER'
       and column_name not in ('id', 'entity_id', 'source_id', 'created_by', 'created_at', 'updated_at');
    execute format(
      'insert into public.%1$I (entity_id, source_id, created_by, %2$s)
       select $1, coalesce(($3 ->> x.source_id::text)::uuid, x.source_id), auth.uid(), %3$s
         from public.%1$I x
        where x.id in (select row_id from internal.ck_plan($2, $4) where copy and tbl = %4$L)',
      t, v_cols, (select string_agg('x.' || c, ', ') from unnest(string_to_array(v_cols, ', ')) c), t)
      using v_new, p_entity, v_map, p_kind;
    get diagnostics n = row_count;
    v_copied := v_copied + n;
  end loop;

  -- links, from the copy's side
  insert into public.relations (subject_id, predicate, object_id, qualifiers, valid_from, valid_from_precision, valid_to,
                                valid_to_precision, confidence, source_id, source_detail, note, created_by)
  select case when r.subject_id = p_entity then v_new else r.subject_id end, r.predicate,
         case when r.object_id = p_entity then v_new else r.object_id end, r.qualifiers,
         r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision, r.confidence,
         coalesce((v_map ->> r.source_id::text)::uuid, r.source_id), r.source_detail, r.note, auth.uid()
    from public.relations r
   where r.id in (select row_id from internal.ck_plan(p_entity, p_kind) where copy and tbl = 'relations');
  get diagnostics n = row_count;
  v_copied := v_copied + n;

  -- tie the copy to the original (occupant ↔ place), over the lifespan
  select * into v_tie from internal.ck_tie(e.kind, p_kind);
  if v_tie.predicate is not null then
    insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision,
                                  confidence, note, created_by)
    values (case when v_tie.copy_is_subject then v_new else p_entity end, v_tie.predicate,
            case when v_tie.copy_is_subject then p_entity else v_new end,
            e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision, 'approximate',
            'Added when “' || e.name || '” was duplicated as a ' || p_kind || '.', auth.uid());
  end if;

  -- the article, as a revision of the new page (citations follow the copied sources)
  select body into v_body from public.articles where entity_id = p_entity;
  if coalesce(v_body, '') <> '' then
    for s in select key, value from jsonb_each_text(v_map) loop
      v_body := replace(v_body, '[cite:' || s.key, '[cite:' || s.value);
    end loop;
    perform public.save_article(v_new, v_body, 'Copied from “' || e.name || '”' || case when p_kind = e.kind then '' else ' (' || e.kind || ')' end);
  end if;

  return jsonb_build_object('id', v_new, 'slug', v_slug, 'copied', v_copied, 'sources', jsonb_array_length(jsonb_path_query_array(v_map, '$.*')));
end;
$$;

