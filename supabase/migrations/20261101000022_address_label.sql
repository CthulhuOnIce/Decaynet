-- =============================================================================
-- Decaynet :: 0022 address labels
--
-- An address can have a house number, a linked street page, and the address
-- "as written in the source" (which already contains the number). Several
-- places built the label as number + (street name, or else the as-written
-- text), so an address entered with both a number and the as-written text but
-- no linked street read "123 123 Main St." The facts view always did it.
--
-- address_label() is now the one rule:
--   linked street   number + street name, in the site's address order
--   otherwise       the as-written text, untouched (the number is added in
--                   front only if the text doesn't contain it)
--   neither         the number alone
-- =============================================================================

create or replace function public.address_label(p_number text, p_street text, p_raw text)
returns text language sql stable set search_path = public as $$
  select case
    when nullif(btrim(p_street), '') is not null then public.format_address(nullif(btrim(p_number), ''), btrim(p_street))
    when nullif(btrim(p_raw), '') is not null then
      case when nullif(btrim(p_number), '') is not null and strpos(lower(p_raw), lower(btrim(p_number))) = 0
           then public.format_address(btrim(p_number), btrim(p_raw))
           else btrim(p_raw) end
    else nullif(btrim(p_number), '')
  end
$$;

comment on function public.address_label(text, text, text) is
  'How an address reads: number + street name when a street is linked, else the address as written (never with the number twice).';

-- The address on a page at a date
create or replace function public.address_at(p_entity uuid, p_at date default current_date)
returns text language sql stable parallel safe set search_path = public as $$
  select public.address_label(a.house_number, public.name_at(a.street_id, coalesce(p_at, current_date)), a.raw_address)
    from public.addresses a
   where a.entity_id = p_entity and a.valid @> coalesce(p_at, current_date)
   order by a.valid_from desc nulls last
   limit 1
$$;

-- Every fact as one row (unchanged but for the address label)
create or replace view public.facts with (security_invoker = true) as
  select 'entity_names'::text as fact_table, f.id, f.entity_id, null::uuid as other_id,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Name: ' || f.name || ' (' || f.name_type || ')' as summary
    from public.entity_names f
  union all
  select 'entity_geometries', f.id, f.entity_id, null,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Geometry: ' || f.role || ' ' || replace(extensions.st_geometrytype(f.geom), 'ST_', '')
    from public.entity_geometries f
  union all
  select 'entity_states', f.id, f.entity_id, null,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Status: ' || f.status
    from public.entity_states f
  union all
  select 'entity_attributes', f.id, f.entity_id, null,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         f.key || ' = ' || (case when jsonb_typeof(f.value) = 'string' then f.value #>> '{}' else f.value::text end)
    from public.entity_attributes f
  union all
  select 'addresses', f.id, f.entity_id, f.street_id,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Address: ' || coalesce(public.address_label(f.house_number, public.name_at(f.street_id, coalesce(f.valid_from, current_date)),
                                                      f.raw_address), '(street)')
    from public.addresses f
  union all
  select 'relations', f.id, f.subject_id, f.object_id,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Relation: ' || f.predicate
    from public.relations f
  union all
  select 'entity_tags', f.id, f.entity_id, null,
         f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision, f.valid,
         f.confidence, f.source_id, f.source_detail, f.note, f.created_by, f.created_at,
         'Tag: ' || t.label
    from public.entity_tags f join public.tags t on t.id = f.tag_id;


-- A page's timeline (unchanged but for the address label)
create or replace function public.entity_timeline(p_entity uuid)
returns table (
  at date,
  at_precision public.date_precision,
  until date,
  until_precision public.date_precision,
  category text,
  label text,
  ref_id uuid,
  ref_slug text,
  ref_kind text,
  ref_name text,
  fact_table text,
  fact_id uuid,
  confidence public.confidence_level,
  source_id uuid,
  color text
)
language sql stable set search_path = public, extensions as $$
  select * from (
    select e.exists_from, e.exists_from_precision, null::date, null::public.date_precision,
           'lifespan', k.start_verb, null::uuid, null, null, null,
           'entities', e.id, e.lifespan_confidence, null::uuid, '#7fae6a'
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.id = p_entity and e.exists_from is not null
    union all
    select e.exists_to, e.exists_to_precision, null, null,
           'lifespan', k.end_verb, null, null, null, null,
           'entities', e.id, e.lifespan_confidence, null, '#5b5150'
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.id = p_entity and e.exists_to is not null
    union all
    select n.valid_from, n.valid_from_precision, n.valid_to, n.valid_to_precision,
           'name', 'Known as “' || n.name || '”' ||
                   case when n.name_type <> 'official' then ' (' || n.name_type || ')' else '' end,
           null, null, null, null,
           'entity_names', n.id, n.confidence, n.source_id, '#d7c9a7'
      from public.entity_names n where n.entity_id = p_entity
    union all
    select s.valid_from, s.valid_from_precision, s.valid_to, s.valid_to_precision,
           'status', ls.label, null, null, null, null,
           'entity_states', s.id, s.confidence, s.source_id, ls.color
      from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
     where s.entity_id = p_entity
    union all
    select a.valid_from, a.valid_from_precision, a.valid_to, a.valid_to_precision,
           'address', 'Address: ' || coalesce(public.address_label(a.house_number,
                      public.name_at(a.street_id, coalesce(a.valid_from, current_date)), a.raw_address), '?'),
           st.id, st.slug, st.kind, st.name,
           'addresses', a.id, a.confidence, a.source_id, '#b9a68a'
      from public.addresses a left join public.entities st on st.id = a.street_id
     where a.entity_id = p_entity
    union all
    select a.valid_from, a.valid_from_precision, a.valid_to, a.valid_to_precision,
           'attribute', ak.label || ': ' ||
                        (case when jsonb_typeof(a.value) = 'string' then a.value #>> '{}' else a.value::text end) ||
                        coalesce(' ' || ak.unit, ''),
           null, null, null, null,
           'entity_attributes', a.id, a.confidence, a.source_id, '#9c8f7a'
      from public.entity_attributes a join public.attribute_keys ak on ak.id = a.key
     where a.entity_id = p_entity
    union all
    select g.valid_from, g.valid_from_precision, g.valid_to, g.valid_to_precision,
           'geometry', initcap(g.role) || ' mapped (' ||
                       lower(replace(st_geometrytype(g.geom), 'ST_', '')) || ')',
           null, null, null, null,
           'entity_geometries', g.id, g.confidence, g.source_id, '#6f8fa6'
      from public.entity_geometries g where g.entity_id = p_entity
    union all
    -- Relations; edges to events are shown at the event's own date
    select coalesce(r.valid_from, case when r.other_kind = 'event' then oe.exists_from end),
           case when r.valid_from is null and r.other_kind = 'event' then oe.exists_from_precision
                else r.valid_from_precision end,
           coalesce(r.valid_to, case when r.other_kind = 'event' then oe.exists_to end),
           case when r.valid_to is null and r.other_kind = 'event' then oe.exists_to_precision
                else r.valid_to_precision end,
           case when r.other_kind = 'event' then 'event'
                when r.other_kind = 'media' then 'media' else 'relation' end,
           case when r.other_kind = 'event' then coalesce(et.label, 'Event')
                else initcap(substr(r.label, 1, 1)) || substr(r.label, 2) end,
           r.other_id, r.other_slug, r.other_kind, r.other_name_then,
           'relations', r.id, r.confidence, r.source_id,
           coalesce(et.color, case when r.other_kind = 'media' then '#8fb3c9' else '#c2562b' end)
      from (
        -- an event linked several ways (occurred_at + affected) appears once
        select distinct on (case when x.other_kind = 'event' then x.other_id else x.id end) x.*
          from public.entity_relations(p_entity) x
         order by case when x.other_kind = 'event' then x.other_id else x.id end, x.sort
      ) r
      join public.entities oe on oe.id = r.other_id
      left join public.event_details ed on ed.entity_id = r.other_id
      left join public.event_types et on et.id = ed.event_type
  ) t (at, at_precision, until, until_precision, category, label, ref_id, ref_slug, ref_kind,
       ref_name, fact_table, fact_id, confidence, source_id, color)
  order by t.at nulls last, array_position(
    array['lifespan', 'name', 'address', 'status', 'event', 'relation', 'attribute', 'geometry', 'media'],
    t.category)
$$;

