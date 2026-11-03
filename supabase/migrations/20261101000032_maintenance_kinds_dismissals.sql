-- =============================================================================
-- Decaynet :: 0032 maintenance by kind; ignoring timeline suggestions
--
-- 1. A photo or document page doesn't need a long article: media pages are no
--    longer flagged "thin_article". maintenance_summary() counts issues and
--    article statuses per kind in one query, so /maintenance can show a queue
--    for each kind of page.
--
-- 2. Timeline cleanup can be wrong. Anyone who can clean timelines can ignore a
--    fix, suggestion or note on a page. The ignore is tied to a fingerprint of
--    that page's timeline (lifespan, conditions, shapes, addresses, names, facts,
--    tags and links, with the linked pages' lifespans): once any of it changes,
--    the ignored items come back, since a suggestion might then make sense.
--    Ignored items don't count in timeline_review().
-- =============================================================================

-- ---------------------------------------------------------------------------- 1. maintenance

create or replace view public.entity_health with (security_invoker = true) as
  with c as (
    select e.id,
           (select count(*) from public.entity_geometries g where g.entity_id = e.id) as geometry_count,
           (select count(*) from public.facts f where f.entity_id = e.id) as fact_count,
           (select count(*) from public.facts f where f.entity_id = e.id and f.source_id is not null) as sourced_fact_count,
           (select count(*) from public.relations r where r.subject_id = e.id or r.object_id = e.id) as relation_count,
           (select count(*) from public.relations r where r.object_id = e.id and r.predicate = 'depicts') as media_count,
           (select count(*) from public.entity_states s where s.entity_id = e.id) as state_count
      from public.entities e
  )
  select e.id, e.slug, e.kind, e.name, e.exists_from, e.exists_to,
         a.status as article_status, a.word_count, a.updated_at as article_updated_at,
         c.geometry_count, c.fact_count, c.sourced_fact_count, c.relation_count, c.media_count, c.state_count,
         array_remove(array[
           case when k.geometry_hint is not null and c.geometry_count = 0 then 'no_geometry' end,
           case when e.kind in ('event', 'media') and public.locate(e.id) is null then 'unlocated' end,
           case when e.exists_from is null then 'no_start_date' end,
           -- a picture can be a stub: its caption is enough
           case when e.kind <> 'media' and coalesce(a.word_count, 0) < 60 then 'thin_article' end,
           case when c.fact_count > 0 and c.sourced_fact_count = 0 then 'unsourced' end,
           case when e.kind in ('building', 'site') and c.state_count = 0 then 'no_lifecycle' end,
           case when e.kind in ('building', 'site', 'street', 'event') and c.media_count = 0 then 'no_media' end,
           case when c.relation_count = 0 then 'orphan' end
         ], null) as issues
    from public.entities e
    join c on c.id = e.id
    join public.entity_kinds k on k.id = e.kind
    left join public.articles a on a.entity_id = e.id;

/** Counts for /maintenance, per kind: pages, issues and article statuses (only what the caller can see). */
create or replace function public.maintenance_summary() returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'pages', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) as n from public.entities group by kind) x), '{}'),
    -- pages with at least one issue
    'flagged', coalesce((select jsonb_object_agg(kind, n)
                           from (select kind, count(*) as n from public.entity_health where cardinality(issues) > 0 group by kind) x), '{}'),
    'issues', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'issue', issue, 'n', n))
                          from (select h.kind, i.issue, count(*) as n
                                  from public.entity_health h cross join lateral unnest(h.issues) as i(issue)
                                 group by 1, 2) x), '[]'),
    'statuses', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'status', status, 'n', n))
                            from (select e.kind, a.status, count(*) as n
                                    from public.articles a join public.entities e on e.id = a.entity_id
                                   group by 1, 2) x), '[]')
  )
$$;
grant execute on function public.maintenance_summary() to anon, authenticated;

-- ---------------------------------------------------------------------------- 2. ignoring suggestions

create table if not exists public.timeline_dismissals (
  entity_id uuid not null references public.entities (id) on delete cascade,
  key text not null,
  fingerprint text not null,
  dismissed_by uuid default auth.uid() references auth.users (id) on delete set null,
  dismissed_at timestamptz not null default now(),
  primary key (entity_id, key)
);
comment on table public.timeline_dismissals is
  'Timeline cleanup items someone ignored. Only valid while the page''s timeline_fingerprint() is unchanged.';

alter table public.timeline_dismissals enable row level security;
drop policy if exists "timeline cleaners read dismissals" on public.timeline_dismissals;
create policy "timeline cleaners read dismissals" on public.timeline_dismissals for select to authenticated
  using ((select public.has_permission('clean_timelines')));
drop policy if exists "timeline cleaners write dismissals" on public.timeline_dismissals;
create policy "timeline cleaners write dismissals" on public.timeline_dismissals for all to authenticated
  using ((select public.has_permission('clean_timelines'))) with check ((select public.has_permission('clean_timelines')));
grant select, insert, update, delete on public.timeline_dismissals to authenticated;

/** A hash of everything timeline_plan() looks at for a page; any edit to it changes the hash. */
create or replace function public.timeline_fingerprint(p_entity uuid) returns text
language sql stable security invoker set search_path = public as $$
  select md5(concat_ws(' | ',
    (select concat_ws(',', exists_from, exists_from_precision, exists_to, exists_to_precision, kind)
       from public.entities where id = p_entity),
    (select string_agg((to_jsonb(t) - 'created_at' - 'updated_at' - 'created_by')::text, ';' order by t.id) from public.entity_states t where t.entity_id = p_entity),
    (select string_agg(concat_ws(',', t.id, t.role, t.valid_from, t.valid_from_precision, t.valid_to, t.valid_to_precision,
                                 md5(extensions.st_asbinary(t.geom)::text)), ';' order by t.id)
       from public.entity_geometries t where t.entity_id = p_entity),
    (select string_agg((to_jsonb(t) - 'created_at' - 'updated_at' - 'created_by')::text, ';' order by t.id) from public.addresses t where t.entity_id = p_entity),
    (select string_agg((to_jsonb(t) - 'created_at' - 'updated_at' - 'created_by')::text, ';' order by t.id) from public.entity_names t where t.entity_id = p_entity),
    (select string_agg((to_jsonb(t) - 'created_at' - 'updated_at' - 'created_by')::text, ';' order by t.id) from public.entity_attributes t where t.entity_id = p_entity),
    (select string_agg((to_jsonb(t) - 'created_at' - 'updated_at' - 'created_by')::text, ';' order by t.id) from public.entity_tags t where t.entity_id = p_entity),
    -- links in both directions, with the other page's lifespan (links are fitted to both)
    (select string_agg(concat_ws(',', (to_jsonb(r) - 'created_at' - 'updated_at' - 'created_by')::text, o.exists_from, o.exists_from_precision, o.exists_to, o.exists_to_precision),
                       ';' order by r.id)
       from public.relations r
       join public.entities o on o.id = case when r.subject_id = p_entity then r.object_id else r.subject_id end
      where r.subject_id = p_entity or r.object_id = p_entity)
  ))
$$;
grant execute on function public.timeline_fingerprint(uuid) to authenticated;

/** Keys ignored on this page while its timeline is as it is now. */
create or replace function public.timeline_dismissed_keys(p_entity uuid) returns text[]
language sql stable security invoker set search_path = public as $$
  select coalesce(array_agg(d.key order by d.key), '{}')
    from public.timeline_dismissals d
   where d.entity_id = p_entity
     and d.fingerprint = public.timeline_fingerprint(p_entity)
$$;
grant execute on function public.timeline_dismissed_keys(uuid) to authenticated;

/** Ignore items until the page's timeline changes (and forget ignores from earlier versions of it). */
create or replace function public.dismiss_timeline_items(p_entity uuid, p_keys text[]) returns int
language plpgsql security invoker set search_path = public as $$
declare
  fp text := public.timeline_fingerprint(p_entity);
  n int;
begin
  if not public.has_permission('clean_timelines') then
    raise exception 'You need the clean_timelines permission' using errcode = '42501';
  end if;
  delete from public.timeline_dismissals where entity_id = p_entity and fingerprint <> fp;
  insert into public.timeline_dismissals (entity_id, key, fingerprint)
  select p_entity, k, fp from unnest(p_keys) as k where nullif(btrim(k), '') is not null
  on conflict (entity_id, key) do update set fingerprint = excluded.fingerprint,
                                             dismissed_by = auth.uid(), dismissed_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;
grant execute on function public.dismiss_timeline_items(uuid, text[]) to authenticated;

/** Bring ignored items back (all of them when p_keys is null). */
create or replace function public.restore_timeline_items(p_entity uuid, p_keys text[] default null) returns int
language plpgsql security invoker set search_path = public as $$
declare n int;
begin
  if not public.has_permission('clean_timelines') then
    raise exception 'You need the clean_timelines permission' using errcode = '42501';
  end if;
  delete from public.timeline_dismissals where entity_id = p_entity and (p_keys is null or key = any (p_keys));
  get diagnostics n = row_count;
  return n;
end;
$$;
grant execute on function public.restore_timeline_items(uuid, text[]) to authenticated;

/** The review list, leaving out what was ignored (pages with nothing else left drop off). */
create or replace function public.timeline_review(p_limit int default 300)
returns table (entity_id uuid, slug text, name text, kind text, fixes int, suggestions int, notes int, sections text[])
language sql stable security invoker set search_path = public as $$
  select e.id, e.slug, e.name, e.kind,
         (select count(*)::int from jsonb_array_elements(p.plan) x where x ->> 'op' <> 'note' and (x ->> 'default')::boolean),
         (select count(*)::int from jsonb_array_elements(p.plan) x where x ->> 'op' <> 'note' and not (x ->> 'default')::boolean),
         (select count(*)::int from jsonb_array_elements(p.plan) x where x ->> 'op' = 'note'),
         array(select distinct x ->> 'section' from jsonb_array_elements(p.plan) x order by 1)
    from public.entities e
    -- the fingerprint is only worked out for pages that have something ignored
    cross join lateral (
      select case when exists (select 1 from public.timeline_dismissals d where d.entity_id = e.id)
                  then public.timeline_dismissed_keys(e.id) else '{}'::text[] end as ignored
    ) dk
    cross join lateral (
      select coalesce(jsonb_agg(x), '[]'::jsonb) as plan
        from jsonb_array_elements(public.timeline_plan(e.id)) x
       where not (x ->> 'key') = any (dk.ignored)
    ) p
   where public.has_permission('clean_timelines')
     and e.kind in ('building', 'site', 'infrastructure', 'street', 'space', 'parcel', 'district', 'water', 'landform', 'event')
     and jsonb_array_length(p.plan) > 0
   order by 5 desc, 6 desc, e.name
   limit greatest(1, least(coalesce(p_limit, 300), 2000))
$$;
