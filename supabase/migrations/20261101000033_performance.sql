-- =============================================================================
-- Decaynet :: 0033 performance
--
-- Measured on a Gary-sized database (~8,000 pages, 11,500 conditions, 6,000
-- shapes), as an anonymous visitor:
--
-- 1. Every fact table's read rule called entity_hidden() per row. It is
--    SECURITY DEFINER, so Postgres can't fold it into the query: reading all
--    facts took 2.2 s (3 ms without the rule). The rules now use
--    entity_visible(): "can this visitor see the page?", answered by the
--    pages' own read rule, which the planner turns into one hashed lookup.
--    Same visibility; reading all facts: 0.2 s.
--    It also closes a hole: a private page with no recorded creator (made by
--    an import) counted as "created by" every anonymous visitor (null is not
--    distinct from null), so its facts were readable. entity_hidden(), still
--    used inside SECURITY DEFINER functions, gets the same fix.
-- 2. entity_health counted each page's facts, shapes, links and conditions
--    with five lookups per page; it now counts each table once and joins
--    (identical results). maintenance_summary() reads it once instead of twice.
--    /maintenance: 15.7 s -> well under a second.
-- 3. Indexes for foreign keys that were scanned without one (a source page's
--    tags and media; tips when a page is deleted).
-- 4. map_snapshot(): the per-feature name, condition and occupant helpers are
--    joins in the one statement (identical output): whole city 4 s -> 0.4 s.
-- 5. chronology(): historical names only for the rows that make the cut.
-- 6. chronology_years(): the home page's slider histogram, per year and
--    complete (it was built from the first 5,000 chronology rows and stopped
--    partway through history on a big site).
-- =============================================================================

-- ---------------------------------------------------------------------------- 1. visibility

create or replace function public.entity_visible(p_id uuid) returns boolean
language sql stable as $$
  -- answered by entities' own read rule (public, yours, or you may see private pages);
  -- kept a plain SQL function (no SECURITY DEFINER, no SET) so the planner can inline it
  select exists (select 1 from public.entities e where e.id = p_id)
$$;
comment on function public.entity_visible(uuid) is
  'Can the current visitor see this page? Used by the read rules of facts, articles, sources, ...';
grant execute on function public.entity_visible(uuid) to anon, authenticated;

do $$
declare p record;
begin
  for p in select * from pg_policies where schemaname = 'public' and qual like '%entity_hidden(%' loop
    execute format('alter policy %I on %I.%I using (%s)', p.policyname, p.schemaname, p.tablename,
                   replace(p.qual, 'NOT entity_hidden(', 'public.entity_visible('));
  end loop;
end;
$$;

create or replace function public.entity_hidden(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.entities e
     where e.id = p_id
       and e.is_private
       and (auth.uid() is null or e.created_by is distinct from auth.uid())
       and not public.has_permission('view_private')
  )
$$;

-- ---------------------------------------------------------------------------- 2. maintenance

create or replace view public.entity_health with (security_invoker = true) as
  with fc as (select f.entity_id, count(*) as n, count(f.source_id) as sourced from public.facts f group by f.entity_id),
       gc as (select g.entity_id, count(*) as n from public.entity_geometries g group by g.entity_id),
       rc as (select x.id, count(*) as n
                from (select r.subject_id as id from public.relations r
                      union all
                      select r.object_id from public.relations r where r.object_id <> r.subject_id) x
               group by x.id),
       mc as (select r.object_id as id, count(*) as n from public.relations r where r.predicate = 'depicts' group by r.object_id),
       sc as (select s.entity_id, count(*) as n from public.entity_states s group by s.entity_id)
  select e.id, e.slug, e.kind, e.name, e.exists_from, e.exists_to,
         a.status as article_status, a.word_count, a.updated_at as article_updated_at,
         coalesce(gc.n, 0) as geometry_count, coalesce(fc.n, 0) as fact_count, coalesce(fc.sourced, 0) as sourced_fact_count,
         coalesce(rc.n, 0) as relation_count, coalesce(mc.n, 0) as media_count, coalesce(sc.n, 0) as state_count,
         array_remove(array[
           case when k.geometry_hint is not null and coalesce(gc.n, 0) = 0 then 'no_geometry' end,
           case when e.kind in ('event', 'media') and public.locate(e.id) is null then 'unlocated' end,
           case when e.exists_from is null then 'no_start_date' end,
           -- a picture can be a stub: its caption is enough
           case when e.kind <> 'media' and coalesce(a.word_count, 0) < 60 then 'thin_article' end,
           case when coalesce(fc.n, 0) > 0 and coalesce(fc.sourced, 0) = 0 then 'unsourced' end,
           case when e.kind in ('building', 'site') and coalesce(sc.n, 0) = 0 then 'no_lifecycle' end,
           case when e.kind in ('building', 'site', 'street', 'event') and coalesce(mc.n, 0) = 0 then 'no_media' end,
           case when coalesce(rc.n, 0) = 0 then 'orphan' end
         ], null) as issues
    from public.entities e
    join public.entity_kinds k on k.id = e.kind
    left join public.articles a on a.entity_id = e.id
    left join fc on fc.entity_id = e.id
    left join gc on gc.entity_id = e.id
    left join rc on rc.id = e.id
    left join mc on mc.id = e.id
    left join sc on sc.entity_id = e.id;

create or replace function public.maintenance_summary() returns jsonb
language sql stable security invoker set search_path = public as $$
  with h as materialized (select kind, issues from public.entity_health)
  select jsonb_build_object(
    'pages', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) as n from public.entities group by kind) x), '{}'),
    -- pages with at least one issue
    'flagged', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) as n from h where cardinality(issues) > 0 group by kind) x), '{}'),
    'issues', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'issue', issue, 'n', n))
                          from (select h.kind, i.issue, count(*) as n
                                  from h cross join lateral unnest(h.issues) as i(issue)
                                 group by 1, 2) x), '[]'),
    'statuses', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'status', status, 'n', n))
                            from (select e.kind, a.status, count(*) as n
                                    from public.articles a join public.entities e on e.id = a.entity_id
                                   group by 1, 2) x), '[]')
  )
$$;

-- ---------------------------------------------------------------------------- 3. indexes

create index if not exists entity_tags_source_idx on public.entity_tags (source_id) where source_id is not null;
create index if not exists media_items_source_idx on public.media_items (source_id) where source_id is not null;
create index if not exists tips_about_entity_idx on public.tips (about_entity_id) where about_entity_id is not null;
create index if not exists tips_resulting_entity_idx on public.tips (resulting_entity_id) where resulting_entity_id is not null;

-- ---------------------------------------------------------------------------- 4. the map

-- name_at(), status_at() and occupant_label() per feature were separate statements, each setting up
-- the read rules again: written out as joins. Identical output; a whole-city snapshot 2-3 s -> 0.3-0.5 s.
create or replace function public.map_snapshot(
  p_at date default current_date,
  p_kinds text[] default null,
  p_west double precision default null,
  p_south double precision default null,
  p_east double precision default null,
  p_north double precision default null,
  p_ghosts boolean default true,
  p_tag text default null
) returns jsonb
language sql stable set search_path = public, extensions as $$
  with bbox as (
    select case when p_west is null then null
                else st_makeenvelope(p_west, p_south, p_east, p_north, 4326) end as env
  ),
  live as (
    select distinct on (g.entity_id, g.role)
           g.entity_id, g.role, g.geom, g.confidence, false as ghost
      from public.entity_geometries g
      join public.entities e on e.id = g.entity_id
     cross join bbox
     where g.role <> 'viewpoint'
       and e.kind not in ('event', 'media')
       and (p_kinds is null or e.kind = any (p_kinds))
       and e.lifespan @> p_at
       and g.valid @> p_at
       and (bbox.env is null or g.geom && bbox.env)
     order by g.entity_id, g.role, g.valid_from desc nulls last
  ),
  ghosts as (
    select distinct on (g.entity_id)
           g.entity_id, g.role, g.geom, g.confidence, true as ghost
      from public.entity_geometries g
      join public.entities e on e.id = g.entity_id
     cross join bbox
     where p_ghosts
       and g.role <> 'viewpoint'
       and e.kind in ('building', 'street', 'site', 'infrastructure', 'parcel', 'water', 'landform')
       and (p_kinds is null or e.kind = any (p_kinds))
       and upper(e.lifespan) <= p_at
       and (bbox.env is null or g.geom && bbox.env)
     order by g.entity_id, g.valid_from desc nulls last
  ),
  tagged as (
    select distinct et.entity_id
      from public.tags root
      join public.tag_tree tt on tt.ancestor_id = root.id
      join public.entity_tags et on et.tag_id = tt.id
     where root.slug = p_tag and et.valid @> p_at
  ),
  feats as (
    select * from (select * from live union all select * from ghosts) x
     where p_tag is null
        or x.entity_id in (select entity_id from tagged)
        -- a tagged tenant lights up the space it occupies
        or x.entity_id in (select r.object_id from public.relations r
                            where r.predicate = 'occupies' and r.valid @> p_at
                              and r.subject_id in (select entity_id from tagged))
  )
  select jsonb_build_object(
    'type', 'FeatureCollection',
    'at', p_at,
    'features', coalesce(jsonb_agg(jsonb_build_object(
      'type', 'Feature',
      'id', f.entity_id,
      'geometry', st_asgeojson(f.geom, 7)::jsonb,
      'properties', jsonb_build_object(
        'id', e.id,
        'slug', e.slug,
        'kind', e.kind,
        'role', f.role,
        'name', nm.name,
        'status', st.id,
        'status_label', st.label,
        'decay', coalesce(st.decay_level, 0),
        'color', coalesce(st.color, k.color),
        'kind_color', k.color,
        'ghost', f.ghost,
        'extant', not f.ghost and coalesce(st.is_extant, true),
        'confidence', f.confidence
      ) || case when e.kind = 'space' then jsonb_build_object(
        'tenant', public.tenants_at(e.id, p_at),
        'floor', public.attribute_at(e.id, 'floor', p_at),
        'vacant_space', public.tenants_at(e.id, p_at) is null
      ) when o.occupant is not null then jsonb_strip_nulls(jsonb_build_object(
        'occupant', o.occupant,
        -- the place's own name, shown under the occupant unless one name contains the other
        -- ("Gary Land Company" in "Gary Land Company Building")
        'place_name', case when not (strpos(lower(o.place), lower(split_part(o.occupant, ' +', 1))) > 0
                                     or strpos(lower(split_part(o.occupant, ' +', 1)), lower(o.place)) > 0)
                           then o.place end
      )) else '{}'::jsonb end
    ) order by k.sort), '[]'::jsonb)
  )
  from feats f
  join public.entities e on e.id = f.entity_id
  join public.entity_kinds k on k.id = e.kind
  -- name_at(), status_at() and occupant_label(), written out as joins (0033): one statement,
  -- so the read rules' checks run once per map rather than once per feature
  cross join lateral (
    select coalesce(
      (select n.name from public.entity_names n
        where n.entity_id = e.id and n.valid @> p_at
          and n.name_type in ('official', 'common', 'historic')
        order by n.valid_from desc nulls last,
                 array_position(array['official', 'common', 'historic'], n.name_type)
        limit 1),
      e.name) as name
  ) nm
  left join lateral (
    select s.status from public.entity_states s
     where s.entity_id = e.id and s.valid @> p_at
     order by s.valid_from desc nulls last
     limit 1
  ) sa on true
  left join public.lifecycle_statuses st on st.id = sa.status
  left join lateral (
    select case when count(*) = 0 then null
                when count(*) = 1 then min(t.name)
                else (array_agg(t.name order by t.ord))[1] || ' +' || (count(*) - 1)
           end as occupant,
           nm.name as place
      from (select coalesce(
                     (select n.name from public.entity_names n
                       where n.entity_id = r.subject_id and n.valid @> p_at
                         and n.name_type in ('official', 'common', 'historic')
                       order by n.valid_from desc nulls last,
                                array_position(array['official', 'common', 'historic'], n.name_type)
                       limit 1),
                     so.name) as name,
                   row_number() over (order by r.valid_from desc nulls last, r.created_at) as ord
              from public.relations r
              join public.entities so on so.id = r.subject_id
             where r.object_id = e.id
               and r.predicate = 'occupies'
               and r.valid @> p_at) t
     where e.kind in ('building', 'site', 'parcel') and not f.ghost
  ) o on true
$$;

-- ---------------------------------------------------------------------------- 5. the chronology

-- name_at() ran for every row before the limit; now only for the rows that make the cut. Identical output.
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
  -- names as they were on the date (name_at) only for the rows that make the cut: the cut-off date
  -- is found first, so ties on it are still ordered by that name (0033)
  with c as (
    select * from (
    select e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision,
           'event', e.id, e.slug, e.kind, e.name, coalesce(et.label, 'Event'), ed.event_type,
           coalesce(et.color, '#e0a23a'), null::text, null::date
      from public.entities e
      left join public.event_details ed on ed.entity_id = e.id
      left join public.event_types et on et.id = ed.event_type
     where e.kind = 'event' and e.exists_from between p_from and p_to
    union all
    select e.exists_from, e.exists_from_precision, null, null,
           'start', e.id, e.slug, e.kind, e.name, k.start_verb, null, '#7fae6a', null::text, e.exists_from
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.kind not in ('event', 'media') and e.exists_from between p_from and p_to
    union all
    select e.exists_to, e.exists_to_precision, null, null,
           'end', e.id, e.slug, e.kind, e.name, k.end_verb, null, '#5b5150', null::text, e.exists_to - 1
      from public.entities e join public.entity_kinds k on k.id = e.kind
     where e.kind not in ('event', 'media') and e.exists_to between p_from and p_to
    union all
    select s.valid_from, s.valid_from_precision, s.valid_to, s.valid_to_precision,
           'status', e.id, e.slug, e.kind, e.name, ls.label, s.status, ls.color, s.description, s.valid_from
      from public.entity_states s
      join public.entities e on e.id = s.entity_id
      join public.lifecycle_statuses ls on ls.id = s.status
     where ls.decay_level >= 2 and s.valid_from between p_from and p_to
    ) c (at, at_precision, until, until_precision, category, entity_id, slug, kind, name, label, subtype, color, description, name_date)
    where p_kinds is null or c.kind = any (p_kinds)
  ),
  cut as (select max(x.at) as last from (select c.at from c order by c.at limit p_limit) x)
  select c.at, c.at_precision, c.until, c.until_precision, c.category, c.entity_id, c.slug, c.kind,
         case when c.name_date is null then c.name else public.name_at(c.entity_id, c.name_date) end as name,
         c.label, c.subtype, c.color, c.description
    from c
   where c.at <= (select cut.last from cut)
   order by c.at, 9
   limit p_limit
$$;

-- ---------------------------------------------------------------------------- 6. the home page's histogram

-- The home page drew its year slider's histogram from chronology(.., 5000): 5,000 named rows to count
-- years, and, oldest first, it stopped partway through history once a site had more. This counts the
-- same dates (keep in step with chronology()) per year, all of them.
create or replace function public.chronology_years(
  p_from date default '1800-01-01',
  p_to date default current_date
) returns table (year int, n int)
language sql stable set search_path = public as $$
  select extract(year from c.at)::int, count(*)::int
    from (
      select e.exists_from as at from public.entities e
       where e.kind = 'event' and e.exists_from between p_from and p_to
      union all
      select e.exists_from from public.entities e
       where e.kind not in ('event', 'media') and e.exists_from between p_from and p_to
      union all
      select e.exists_to from public.entities e
       where e.kind not in ('event', 'media') and e.exists_to between p_from and p_to
      union all
      select s.valid_from
        from public.entity_states s
        join public.entities e on e.id = s.entity_id
        join public.lifecycle_statuses ls on ls.id = s.status
       where ls.decay_level >= 2 and s.valid_from between p_from and p_to
    ) c
   group by 1
   order by 1
$$;
grant execute on function public.chronology_years(date, date) to anon, authenticated;
