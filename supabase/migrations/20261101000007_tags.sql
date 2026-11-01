-- =============================================================================
-- Decaynet :: 0007 tags (hierarchical traits)
--
-- Tags are a tree grouped into facets: "Business type > Food & drink > Soul
-- food", "Architecture > Art Deco", "Topic > Labor". A tag on a specific
-- sub-trait implies all its ancestors, so filtering by "Food & drink" also
-- finds the soul-food diner.
--
-- Tagging is just another temporal component (entity_tags), so a storefront
-- can be a Bar 1950–1972 and a Church afterwards. Any entity can be tagged:
-- articles (every entity has one), media items, organizations (business type),
-- buildings (architecture, use), events (topic)...
-- =============================================================================

create table public.tag_facets (
  id text primary key,
  label text not null,
  description text,
  applies_to text[],                -- entity kinds this facet makes sense for (null = any)
  color text not null default '#b9a68a',
  sort smallint not null default 100
);

create table public.tags (
  id uuid primary key default gen_random_uuid(),
  facet text not null references public.tag_facets (id),
  parent_id uuid references public.tags (id) on delete restrict,
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  label text not null,
  description text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  constraint tag_not_own_parent check (parent_id is null or parent_id <> id)
);
create index tags_parent_idx on public.tags (parent_id);
create index tags_facet_idx on public.tags (facet);

-- A child must live in its parent's facet, and the tree must not loop
create or replace function internal.guard_tag_tree() returns trigger
language plpgsql as $$
begin
  if new.parent_id is null then return new; end if;
  if (select facet from public.tags where id = new.parent_id) <> new.facet then
    raise exception 'A sub-trait must be in the same facet as its parent' using errcode = '23514';
  end if;
  if exists (
    with recursive up as (
      select id, parent_id from public.tags where id = new.parent_id
      union all
      select t.id, t.parent_id from public.tags t join up on t.id = up.parent_id
    ) select 1 from up where id = new.id
  ) then
    raise exception 'Tag hierarchy cannot contain a cycle' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger guard_tree before insert or update on public.tags
  for each row execute function internal.guard_tag_tree();

-- Temporal tagging component
create table public.entity_tags (
  like internal.temporal_fact including all,
  entity_id uuid not null references public.entities (id) on delete cascade,
  tag_id uuid not null references public.tags (id) on delete cascade
);
alter table public.entity_tags add constraint entity_tags_source_fk
  foreign key (source_id) references public.sources (id) on delete set null;
create index entity_tags_entity_idx on public.entity_tags (entity_id);
create index entity_tags_tag_idx on public.entity_tags (tag_id);
create index entity_tags_valid_idx on public.entity_tags using gist (valid);
create trigger touch before update on public.entity_tags for each row execute function internal.touch_updated_at();
create trigger log_change after insert or update or delete on public.entity_tags
  for each row execute function internal.log_change();

-- -----------------------------------------------------------------------------
-- Closure: every tag paired with itself and each ancestor, with depth and path
-- -----------------------------------------------------------------------------
create or replace view public.tag_tree with (security_invoker = true) as
  with recursive walk as (
    select t.id, t.id as ancestor_id, 0 as depth, array[t.label] as path_labels
      from public.tags t
    union all
    select w.id, p.parent_id, w.depth + 1, pp.label || w.path_labels
      from walk w
      join public.tags p on p.id = w.ancestor_id
      join public.tags pp on pp.id = p.parent_id
  )
  select w.id, w.ancestor_id, w.depth, w.path_labels
    from walk w;

-- Tag with its full path ("Food & drink › Soul food") and usage count
create or replace view public.tag_index with (security_invoker = true) as
  select t.id, t.slug, t.label, t.facet, f.label as facet_label, f.color, t.parent_id, t.description,
         (select array_to_string(tt.path_labels, ' › ') from public.tag_tree tt
           where tt.id = t.id order by tt.depth desc limit 1) as path,
         (select max(tt.depth) from public.tag_tree tt where tt.id = t.id) as depth,
         (select count(*) from public.entity_tags et where et.tag_id = t.id) as direct_uses,
         (select count(distinct et.entity_id) from public.entity_tags et
            join public.tag_tree tt on tt.id = et.tag_id where tt.ancestor_id = t.id) as total_uses
    from public.tags t
    join public.tag_facets f on f.id = t.facet;

-- Tags on an entity as of a date, including implied ancestors
create or replace function public.tags_at(p_entity uuid, p_at date default null)
returns table (tag_id uuid, slug text, label text, facet text, facet_label text, color text,
               path text, implied boolean, valid_from date, valid_from_precision public.date_precision,
               valid_to date, valid_to_precision public.date_precision, fact_id uuid)
language sql stable set search_path = public as $$
  select distinct on (ti.id)
         ti.id, ti.slug, ti.label, ti.facet, ti.facet_label, ti.color, ti.path,
         tt.depth > 0, et.valid_from, et.valid_from_precision, et.valid_to, et.valid_to_precision,
         case when tt.depth = 0 then et.id end
    from public.entity_tags et
    join public.tag_tree tt on tt.id = et.tag_id
    join public.tag_index ti on ti.id = tt.ancestor_id
   where et.entity_id = p_entity
     and (p_at is null or et.valid @> p_at)
   order by ti.id, tt.depth
$$;

-- Entities carrying a tag or any of its sub-traits (optionally as of a date)
create or replace function public.entities_tagged(p_tag text, p_at date default null, p_limit integer default 500)
returns table (id uuid, slug text, kind text, name text, via_tag text, via_label text,
               valid_from date, valid_from_precision public.date_precision,
               valid_to date, valid_to_precision public.date_precision)
language sql stable set search_path = public as $$
  select e.id, e.slug, e.kind, public.name_at(e.id, coalesce(p_at, et.valid_from, current_date)),
         t.slug, t.label, et.valid_from, et.valid_from_precision, et.valid_to, et.valid_to_precision
    from public.tags root
    join public.tag_tree tt on tt.ancestor_id = root.id
    join public.entity_tags et on et.tag_id = tt.id
    join public.tags t on t.id = et.tag_id
    join public.entities e on e.id = et.entity_id
   where root.slug = p_tag
     and (p_at is null or et.valid @> p_at)
   order by e.name
   limit p_limit
$$;

-- RLS
alter table public.tag_facets enable row level security;
create policy "read tag_facets" on public.tag_facets for select to anon, authenticated using (true);
create policy "moderators write tag_facets" on public.tag_facets for all to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));

alter table public.tags enable row level security;
create policy "read tags" on public.tags for select to anon, authenticated using (true);
create policy "contributors create tags" on public.tags for insert to authenticated
  with check ((select public.is_editor()));
create policy "moderators edit tags" on public.tags for update to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));
create policy "moderators delete tags" on public.tags for delete to authenticated
  using ((select public.is_moderator()));

alter table public.entity_tags enable row level security;
create policy "read entity_tags" on public.entity_tags for select to anon, authenticated using (true);
create policy "contributors insert entity_tags" on public.entity_tags for insert to authenticated
  with check ((select public.is_editor()));
create policy "contributors update entity_tags" on public.entity_tags for update to authenticated
  using ((select public.is_editor())) with check ((select public.is_editor()));
create policy "moderators or owners delete entity_tags" on public.entity_tags for delete to authenticated
  using ((select public.is_moderator()) or (created_by = (select auth.uid()) and (select public.is_editor())));

-- Tags join the unified fact view (so they're citable and show in health counts)
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
         'Address: ' || coalesce(f.house_number || ' ', '') || coalesce(f.raw_address, '(street)')
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

-- -----------------------------------------------------------------------------
-- Starter vocabulary
-- -----------------------------------------------------------------------------
insert into public.tag_facets (id, label, description, applies_to, color, sort) values
  ('business_type', 'Business type', 'What an organization did or what a storefront housed.', '{organization,building,site}', '#b48ead', 10),
  ('architecture',  'Architecture',  'Style, form and construction.',                            '{building,site,infrastructure}', '#c9b48a', 20),
  ('topic',         'Topic',         'Themes that cut across places and eras.',                   null,                              '#8fb3c9', 30),
  ('media_subject', 'Media subject', 'What a photo, map or document shows.',                       '{media}',                         '#7fae6a', 40),
  ('era',           'Era',           'Named periods in the city''s history.',                     null,                              '#e0a23a', 50);

create function pg_temp.tag(p_facet text, p_slug text, p_label text, p_parent text default null)
returns void language sql as $$
  insert into public.tags (facet, slug, label, parent_id)
  values (p_facet, p_slug, p_label, (select id from public.tags where slug = p_parent))
$$;

select pg_temp.tag('business_type', 'food-and-drink', 'Food & drink');
select pg_temp.tag('business_type', 'restaurant', 'Restaurant', 'food-and-drink');
select pg_temp.tag('business_type', 'soul-food', 'Soul food', 'restaurant');
select pg_temp.tag('business_type', 'diner', 'Diner', 'restaurant');
select pg_temp.tag('business_type', 'bar-tavern', 'Bar / tavern', 'food-and-drink');
select pg_temp.tag('business_type', 'retail', 'Retail');
select pg_temp.tag('business_type', 'department-store', 'Department store', 'retail');
select pg_temp.tag('business_type', 'grocery', 'Grocery', 'retail');
select pg_temp.tag('business_type', 'entertainment', 'Entertainment');
select pg_temp.tag('business_type', 'movie-theater', 'Movie theater', 'entertainment');
select pg_temp.tag('business_type', 'music-venue', 'Music venue', 'entertainment');
select pg_temp.tag('business_type', 'lodging', 'Lodging');
select pg_temp.tag('business_type', 'hotel', 'Hotel', 'lodging');
select pg_temp.tag('business_type', 'religious', 'Religious');
select pg_temp.tag('business_type', 'church', 'Church', 'religious');
select pg_temp.tag('business_type', 'industrial', 'Industrial');
select pg_temp.tag('business_type', 'steel', 'Steel', 'industrial');
select pg_temp.tag('business_type', 'civic', 'Civic / government');
select pg_temp.tag('business_type', 'school', 'School', 'civic');
select pg_temp.tag('business_type', 'transportation', 'Transportation');
select pg_temp.tag('business_type', 'rail-station', 'Rail station', 'transportation');
select pg_temp.tag('architecture', 'beaux-arts', 'Beaux-Arts');
select pg_temp.tag('architecture', 'gothic-revival', 'Gothic Revival');
select pg_temp.tag('architecture', 'art-deco', 'Art Deco');
select pg_temp.tag('architecture', 'neoclassical', 'Neoclassical');
select pg_temp.tag('architecture', 'concrete', 'Reinforced concrete');
select pg_temp.tag('topic', 'urban-decay', 'Urban decay');
select pg_temp.tag('topic', 'abandonment', 'Abandonment', 'urban-decay');
select pg_temp.tag('topic', 'demolition', 'Demolition', 'urban-decay');
select pg_temp.tag('topic', 'arson-and-fire', 'Arson & fire', 'urban-decay');
select pg_temp.tag('topic', 'labor', 'Labor');
select pg_temp.tag('topic', 'civil-rights', 'Civil rights');
select pg_temp.tag('topic', 'music', 'Music');
select pg_temp.tag('topic', 'film-locations', 'Film locations');
select pg_temp.tag('media_subject', 'streetscape', 'Streetscape');
select pg_temp.tag('media_subject', 'interior', 'Interior');
select pg_temp.tag('media_subject', 'aerial-view', 'Aerial view');
select pg_temp.tag('media_subject', 'people', 'People');
select pg_temp.tag('media_subject', 'signage', 'Signage');
select pg_temp.tag('era', 'company-town', 'Company town (1906–1920s)');
select pg_temp.tag('era', 'boom-years', 'Boom years (1920s–1950s)');
select pg_temp.tag('era', 'decline', 'Decline (1960s–1990s)');

-- -----------------------------------------------------------------------------
-- map_snapshot gains a tag filter ("show me every bar in 1955")
-- -----------------------------------------------------------------------------
drop function public.map_snapshot(date, text[], double precision, double precision, double precision, double precision, boolean);

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
    -- Things that are gone by p_at: drawn at their last known shape
    select distinct on (g.entity_id)
           g.entity_id, g.role, g.geom, g.confidence, true as ghost
      from public.entity_geometries g
      join public.entities e on e.id = g.entity_id
     cross join bbox
     where p_ghosts
       and g.role <> 'viewpoint'
       and e.kind in ('building', 'street', 'site', 'infrastructure', 'parcel')
       and (p_kinds is null or e.kind = any (p_kinds))
       and upper(e.lifespan) <= p_at
       and (bbox.env is null or g.geom && bbox.env)
     order by g.entity_id, g.valid_from desc nulls last
  ),
  tagged as (
    -- entities carrying p_tag or any sub-trait of it on p_at
    select distinct et.entity_id
      from public.tags root
      join public.tag_tree tt on tt.ancestor_id = root.id
      join public.entity_tags et on et.tag_id = tt.id
     where root.slug = p_tag and et.valid @> p_at
  ),
  feats as (
    select * from (select * from live union all select * from ghosts) x
     where p_tag is null or x.entity_id in (select entity_id from tagged)
  )
  select jsonb_build_object(
    'type', 'FeatureCollection',
    'at', p_at,
    'features', coalesce(jsonb_agg(jsonb_build_object(
      'type', 'Feature',
      'id', f.entity_id,
      'geometry', st_asgeojson(f.geom, 6)::jsonb,
      'properties', jsonb_build_object(
        'id', e.id,
        'slug', e.slug,
        'kind', e.kind,
        'role', f.role,
        'name', public.name_at(e.id, p_at),
        'status', st.id,
        'status_label', st.label,
        'decay', coalesce(st.decay_level, 0),
        'color', coalesce(st.color, k.color),
        'kind_color', k.color,
        'ghost', f.ghost,
        'extant', not f.ghost and coalesce(st.is_extant, true),
        'confidence', f.confidence
      )
    ) order by k.sort desc), '[]'::jsonb)
  )
  from feats f
  join public.entities e on e.id = f.entity_id
  join public.entity_kinds k on k.id = e.kind
  left join public.lifecycle_statuses st on st.id = public.status_at(e.id, p_at)
$$;

