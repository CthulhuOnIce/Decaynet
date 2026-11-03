-- =============================================================================
-- Decaynet :: 0028 descriptions on conditions
--
-- A condition ("Vacant from 1970") can carry a short description that gives the
-- timeline its context: "Closed after the 1970 fire; owner moved operations to
-- Chicago." It is public text shown under the condition on the page timeline and
-- the city timeline, separate from the internal note (which tools also use).
-- =============================================================================

alter table public.entity_states
  add column if not exists description text
  constraint entity_states_description_length check (char_length(description) <= 1000);

comment on column public.entity_states.description is
  'Optional public context for this condition, shown on the timelines (the note stays internal).';

-- Both functions gain a description column, so they are recreated (as in 0022 / 0004 otherwise)
drop function if exists public.entity_timeline(uuid);
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
  color text,
  description text
)
language sql stable set search_path = public, extensions as $$
  select * from (
    select e.exists_from, e.exists_from_precision, null::date, null::public.date_precision,
           'lifespan', k.start_verb, null::uuid, null, null, null,
           'entities', e.id, e.lifespan_confidence, null::uuid, '#7fae6a', null::text
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.id = p_entity and e.exists_from is not null
    union all
    select e.exists_to, e.exists_to_precision, null, null,
           'lifespan', k.end_verb, null, null, null, null,
           'entities', e.id, e.lifespan_confidence, null, '#5b5150', null::text
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.id = p_entity and e.exists_to is not null
    union all
    select n.valid_from, n.valid_from_precision, n.valid_to, n.valid_to_precision,
           'name', 'Known as “' || n.name || '”' ||
                   case when n.name_type <> 'official' then ' (' || n.name_type || ')' else '' end,
           null, null, null, null,
           'entity_names', n.id, n.confidence, n.source_id, '#d7c9a7', null::text
      from public.entity_names n where n.entity_id = p_entity
    union all
    select s.valid_from, s.valid_from_precision, s.valid_to, s.valid_to_precision,
           'status', ls.label, null, null, null, null,
           'entity_states', s.id, s.confidence, s.source_id, ls.color, s.description
      from public.entity_states s join public.lifecycle_statuses ls on ls.id = s.status
     where s.entity_id = p_entity
    union all
    select a.valid_from, a.valid_from_precision, a.valid_to, a.valid_to_precision,
           'address', 'Address: ' || coalesce(public.address_label(a.house_number,
                      public.name_at(a.street_id, coalesce(a.valid_from, current_date)), a.raw_address), '?'),
           st.id, st.slug, st.kind, st.name,
           'addresses', a.id, a.confidence, a.source_id, '#b9a68a', null::text
      from public.addresses a left join public.entities st on st.id = a.street_id
     where a.entity_id = p_entity
    union all
    select a.valid_from, a.valid_from_precision, a.valid_to, a.valid_to_precision,
           'attribute', ak.label || ': ' ||
                        (case when jsonb_typeof(a.value) = 'string' then a.value #>> '{}' else a.value::text end) ||
                        coalesce(' ' || ak.unit, ''),
           null, null, null, null,
           'entity_attributes', a.id, a.confidence, a.source_id, '#9c8f7a', null::text
      from public.entity_attributes a join public.attribute_keys ak on ak.id = a.key
     where a.entity_id = p_entity
    union all
    select g.valid_from, g.valid_from_precision, g.valid_to, g.valid_to_precision,
           'geometry', initcap(g.role) || ' mapped (' ||
                       lower(replace(st_geometrytype(g.geom), 'ST_', '')) || ')',
           null, null, null, null,
           'entity_geometries', g.id, g.confidence, g.source_id, '#6f8fa6', null::text
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
           coalesce(et.color, case when r.other_kind = 'media' then '#8fb3c9' else '#c2562b' end), null::text
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
       ref_name, fact_table, fact_id, confidence, source_id, color, description)
  order by t.at nulls last, array_position(
    array['lifespan', 'name', 'address', 'status', 'event', 'relation', 'attribute', 'geometry', 'media'],
    t.category)
$$;


drop function if exists public.chronology(date, date, text[], integer);
create or replace function public.chronology(
  p_from date default '1800-01-01',
  p_to date default current_date,
  p_kinds text[] default null,
  p_limit integer default 500
) returns table (
  at date,
  at_precision public.date_precision,
  until date,
  until_precision public.date_precision,
  category text,
  entity_id uuid,
  slug text,
  kind text,
  name text,
  label text,
  subtype text,
  color text,
  description text
)
language sql stable set search_path = public as $$
  select * from (
    select e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision,
           'event', e.id, e.slug, e.kind, e.name, coalesce(et.label, 'Event'), ed.event_type,
           coalesce(et.color, '#e0a23a'), null::text
      from public.entities e
      left join public.event_details ed on ed.entity_id = e.id
      left join public.event_types et on et.id = ed.event_type
     where e.kind = 'event' and e.exists_from between p_from and p_to
    union all
    select e.exists_from, e.exists_from_precision, null, null,
           'start', e.id, e.slug, e.kind, public.name_at(e.id, e.exists_from), k.start_verb, null, '#7fae6a', null::text
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.kind not in ('event', 'media') and e.exists_from between p_from and p_to
    union all
    select e.exists_to, e.exists_to_precision, null, null,
           'end', e.id, e.slug, e.kind, public.name_at(e.id, e.exists_to - 1), k.end_verb, null, '#5b5150', null::text
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.kind not in ('event', 'media') and e.exists_to between p_from and p_to
    union all
    select s.valid_from, s.valid_from_precision, s.valid_to, s.valid_to_precision,
           'status', e.id, e.slug, e.kind, public.name_at(e.id, s.valid_from), ls.label, s.status, ls.color, s.description
      from public.entity_states s
      join public.entities e on e.id = s.entity_id
      join public.lifecycle_statuses ls on ls.id = s.status
     where ls.decay_level >= 2 and s.valid_from between p_from and p_to
  ) c (at, at_precision, until, until_precision, category, entity_id, slug, kind, name, label, subtype, color, description)
  where p_kinds is null or c.kind = any (p_kinds)
  order by c.at, c.name
  limit p_limit
$$;


grant execute on function public.entity_timeline(uuid) to anon, authenticated;
grant execute on function public.chronology(date, date, text[], integer) to anon, authenticated;
