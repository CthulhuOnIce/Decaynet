-- =============================================================================
-- Decaynet :: 0025 undated links take their source's dates
--
-- A link with no dates at all (an event "affected" a building, a business
-- "occupies" it, a building "is on" a street) is dated twice in practice: once
-- on the event or business page, and again on the link. Timeline cleanup now
-- fills it from its source:
--   * an event on either side: the event's dates; an event with one date makes
--     the link a single moment (a purchase in 1981 affected the building in 1981)
--   * otherwise the subject's lifespan, kept within the other side's
-- then the existing rules still apply (occupancy ends when the place goes out
-- of use, links stay within both lifespans). Media "depicts" (the depicted
-- period) and "designed / built by" (end at construction) are left to their
-- own rules. Works on any page, so event pages are cleaned and listed too.
-- Links to pages the viewer can't see are left out of the plan.
-- =============================================================================

-- Timeline plan (as in 0024, plus undated links)
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
  v_src text;
  sf date; sfp text; st date; stp text;
  of_ date; ofp text; ot date; otp text;
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
  -- ================================================================ undated links
  -- A link with no dates takes them from its source: the event when either side is
  -- one ("affected by" a purchase happened when the purchase did; a one-date event
  -- makes it a single moment), otherwise the subject's lifespan, kept within the
  -- other side's. Place links of a place are handled with its other relation rules
  -- below; media "depicts" carries the depicted period; "designed / built by" end
  -- at construction.
  for g in
    select r.id, case when r.subject_id = p_entity then rt.label else rt.inverse_label end || ' ' || o.name as label,
           s.kind as s_kind, s.name as s_name, s.exists_from as s_from, s.exists_from_precision::text as s_fp,
           s.exists_to as s_to, s.exists_to_precision::text as s_tp,
           ob.kind as o_kind, ob.name as o_name, ob.exists_from as ob_from, ob.exists_from_precision::text as ob_fp,
           ob.exists_to as ob_to, ob.exists_to_precision::text as ob_tp
      from public.relations r
      join public.relation_types rt on rt.id = r.predicate
      join public.entities s on s.id = r.subject_id
      join public.entities ob on ob.id = r.object_id
      join public.entities o on o.id = case when r.subject_id = p_entity then r.object_id else r.subject_id end
     where (r.subject_id = p_entity or r.object_id = p_entity)
       and r.valid_from is null and r.valid_to is null
       and r.predicate not in ('depicts', 'mentions', 'designed_by', 'built_by')
       and not public.entity_hidden(o.id)
       and not (physical and ((r.object_id = p_entity and r.predicate in ('occupies', 'resides_at', 'owns', 'part_of'))
                           or (r.subject_id = p_entity and r.predicate in ('located_on', 'located_in', 'part_of', 'intersects', 'designed_by', 'built_by'))))
     order by r.predicate, o.name
  loop
    -- the source: an event on either side, else the subject; the other side bounds it
    if g.s_kind = 'event' or g.o_kind <> 'event' then
      v_src := g.s_name; sf := g.s_from; sfp := g.s_fp; st := g.s_to; stp := g.s_tp;
      of_ := g.ob_from; ofp := g.ob_fp; ot := g.ob_to; otp := g.ob_tp;
    else
      v_src := g.o_name; sf := g.ob_from; sfp := g.ob_fp; st := g.ob_to; stp := g.ob_tp;
      of_ := g.s_from; ofp := g.s_fp; ot := g.s_to; otp := g.s_tp;
    end if;
    if g.s_kind = 'event' or g.o_kind = 'event' then
      -- an event with one date is a moment
      if st is null and sf is not null then st := sf; stp := sfp; end if;
    else
      if of_ is not null and (sf is null or of_ > sf) then sf := of_; sfp := ofp; end if;
      if ot is not null and (st is null or ot < st) then st := ot; stp := otp; end if;
    end if;
    continue when sf is null and st is null;
    continue when sf is not null and st is not null and st < sf;   -- they never overlapped
    plan := plan || jsonb_build_object('key', 'from_source:' || g.id, 'op', 'update', 'rule', 'from_source',
      'why', '["from_source"]'::jsonb, 'sets', '["start", "end"]'::jsonb, 'source', v_src,
      'section', 'relations', 'table', 'relations', 'id', g.id, 'label', g.label, 'default', true,
      'before', internal.tl_range(null, sfp, null, stp), 'after', internal.tl_range(sf, sfp, st, stp));
  end loop;

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
           o.exists_from as o_from, o.exists_from_precision::text as o_fp, o.exists_to as o_to, o.exists_to_precision::text as o_tp,
           o.name as o_name, r.subject_id = p_entity as page_is_subject
      from public.relations r
      join public.relation_types rt on rt.id = r.predicate
      join public.entities o on o.id = case when r.subject_id = p_entity then r.object_id else r.subject_id end
      left join public.entities sp on sp.id = r.object_id and r.object_id <> p_entity and r.subject_id <> p_entity
     where not public.entity_hidden(o.id) and ((r.object_id = p_entity and r.predicate in ('occupies', 'resides_at', 'owns', 'part_of'))
        or (r.subject_id = p_entity and r.predicate in ('located_on', 'located_in', 'part_of', 'intersects', 'designed_by', 'built_by'))
        or (r.predicate in ('occupies', 'resides_at')
            and r.object_id in (select x.subject_id from public.relations x join public.entities s on s.id = x.subject_id
                                 where x.object_id = p_entity and x.predicate = 'part_of' and s.kind = 'space')))
     order by r.predicate, r.valid_from nulls first
  loop
    nf := g.valid_from; nfp := g.fp; nt := g.valid_to; ntp := g.tp;
    rwhy := '{}'; rsets := '{}'; v_use := null; v_src := null;

    if g.predicate in ('designed_by', 'built_by') then
      -- design and construction end when it's built
      if g.valid_to is null and b is not null and (g.valid_from is null or g.valid_from <= b) then
        nt := b; ntp := bp; rwhy := array_append(rwhy, 'construction'); rsets := array_append(rsets, 'end');
      end if;
      lb := null;
    else
      -- no dates at all: take the subject's lifespan (the bounds below keep it within both sides')
      if g.valid_from is null and g.valid_to is null then
        if g.page_is_subject then
          nf := b; nfp := bp; nt := e; ntp := ep; v_src := en.name;
        else
          nf := g.o_from; nfp := g.o_fp; nt := g.o_to; ntp := g.o_tp; v_src := g.o_name;
        end if;
        if nf is not null then rwhy := array_append(rwhy, 'from_source'); rsets := array_append(rsets, 'start'); end if;
        if nt is not null then rwhy := array_append(rwhy, 'from_source'); rsets := array_append(rsets, 'end'); end if;
        rwhy := array(select distinct x from unnest(rwhy) x);
      end if;
      -- within both lifespans
      lb := case when g.o_from is not null and (b is null or g.o_from > b) then g.o_from else b end;
      lbp := case when g.o_from is not null and (b is null or g.o_from > b) then g.o_fp else bp end;
      ub := case when g.o_to is not null and (e is null or g.o_to < e) then g.o_to else e end;
      ubp := case when g.o_to is not null and (e is null or g.o_to < e) then g.o_tp else ep end;
      if (lb is not null and nt is not null and internal.tl_before(nt, ntp, lb, lbp))
         or (ub is not null and nf is not null and internal.tl_after(nf, nfp, ub, ubp)) then
        plan := plan || jsonb_build_object('key', 'note:relations:' || g.id, 'op', 'note', 'rule', 'outside', 'section', 'relations',
          'table', 'relations', 'id', g.id, 'label', g.label, 'default', false,
          'before', internal.tl_range(g.valid_from, g.fp, g.valid_to, g.tp));
        continue;
      end if;
      if nf is not null and lb is not null and internal.tl_before(nf, nfp, lb, lbp) then
        nf := lb; nfp := lbp; rwhy := array_append(rwhy, 'start');
        if not ('start' = any (rsets)) then rsets := array_append(rsets, 'start'); end if;
      end if;
      if ub is not null and (nt is null or internal.tl_after(nt, ntp, ub, ubp)) then
        nt := ub; ntp := ubp; rwhy := array_append(rwhy, 'end');
        if not ('end' = any (rsets)) then rsets := array_append(rsets, 'end'); end if;
      end if;

      -- occupancy ends when the place stops being in use
      if g.predicate in ('occupies', 'resides_at') then
        select s.valid_from, s.valid_from_precision::text as fp, ls.label into u
          from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
         where s.entity_id = p_entity and s.valid_from is not null
           and not (ls.is_extant and ls.decay_level <= 1) and s.status not in ('proposed', 'under_construction')
           and case when nf is not null then s.valid_from > nf
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
                     when 'from_source' = any (rwhy) then 'from_source' else 'fit_relation' end,
        'why', to_jsonb(rwhy), 'sets', to_jsonb(rsets), 'use', v_use, 'source', v_src,
        'section', 'relations', 'table', 'relations', 'id', g.id, 'label', g.label, 'default', true,
        'before', internal.tl_range(g.valid_from, g.fp, g.valid_to, g.tp),
        'after', internal.tl_range(nf, nfp, nt, ntp));
    end if;
    -- an undated occupancy or ownership could start when the place was built (a suggestion:
    -- often it was later); undated "is on" / "part of" links just mean "always"
    if nf is null and lb is not null and g.predicate in ('occupies', 'resides_at', 'owns') then
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


-- Pages with something to fix, now including events (otherwise as in 0019)
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
     and e.kind in ('building', 'site', 'infrastructure', 'street', 'space', 'parcel', 'district', 'water', 'landform', 'event')
     and jsonb_array_length(p.plan) > 0
   order by 5 desc, 6 desc, e.name
   limit greatest(1, least(coalesce(p_limit, 300), 2000))
$$;

