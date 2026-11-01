-- =============================================================================
-- Decaynet :: 0014 private pages
--
-- A page (entity) can be private: hidden from the public until it's ready.
-- Enforced with row-level security, so it holds everywhere: map snapshots,
-- search, timelines, history, the REST API. A private page is visible only to
-- its creator and to roles with the view_private permission. Every table that
-- hangs off an entity inherits that visibility.
--
-- Known limit: media FILES live in a public storage bucket under unguessable
-- paths; the media page and its metadata are hidden, but a leaked file URL
-- still works.
-- =============================================================================

alter table public.entities
  add column is_private boolean not null default false,
  add column published_at timestamptz;
create index entities_private_idx on public.entities (is_private) where is_private;

-- Already-public pages count as published now
update public.entities set published_at = coalesce(created_at, now()) where not is_private and published_at is null;

insert into public.permissions (id, label, description, sort) values
  ('view_private', 'View private pages', 'See and work on pages that are hidden from the public until published.', 15)
on conflict (id) do nothing;
insert into public.role_permissions (role, permission)
select r, 'view_private' from unnest(array['contributor', 'editor', 'moderator']) r
where exists (select 1 from public.roles where id = r)
on conflict do nothing;

alter table public.site_settings
  add column new_pages_private boolean not null default false;

-- Stamp published_at when a page goes public
create or replace function internal.stamp_published() returns trigger
language plpgsql as $$
begin
  if not new.is_private and (tg_op = 'INSERT' or old.is_private) then
    new.published_at := now();
  end if;
  return new;
end;
$$;
create trigger stamp_published before insert or update of is_private on public.entities
  for each row execute function internal.stamp_published();

-- -----------------------------------------------------------------------------
-- Visibility helper (security definer so it can see private rows to decide)
-- -----------------------------------------------------------------------------
create or replace function public.entity_hidden(p_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.entities e
     where e.id = p_id
       and e.is_private
       and e.created_by is distinct from auth.uid()
       and not public.has_permission('view_private')
  )
$$;

-- -----------------------------------------------------------------------------
-- Policies
-- -----------------------------------------------------------------------------
drop policy "read entities" on public.entities;
create policy "read public or permitted entities" on public.entities for select to anon, authenticated
  using (not is_private
         or created_by = (select auth.uid())
         or (select public.has_permission('view_private')));

do $$
declare t text;
begin
  -- Tables keyed by entity_id
  foreach t in array array['entity_names', 'entity_geometries', 'entity_states', 'entity_attributes',
                           'addresses', 'event_details', 'media_items', 'articles', 'article_revisions',
                           'article_status_events', 'entity_tags', 'entity_external_ids'] loop
    execute format('drop policy if exists "read %1$s" on public.%1$I', t);
    execute format('create policy "read visible %1$s" on public.%1$I for select to anon, authenticated
                      using ((select public.has_permission(''view_private'')) or not public.entity_hidden(entity_id))', t);
  end loop;
end $$;

-- Relations: both ends must be visible
drop policy "read relations" on public.relations;
create policy "read visible relations" on public.relations for select to anon, authenticated
  using ((select public.has_permission('view_private'))
         or (not public.entity_hidden(subject_id) and not public.entity_hidden(object_id)));

-- History: hide entries about private pages (entries for deleted pages stay visible)
drop policy "read change_log" on public.change_log;
create policy "read visible change_log" on public.change_log for select to anon, authenticated
  using (entity_id is null or (select public.has_permission('view_private')) or not public.entity_hidden(entity_id));

-- Tips that point at a private page are for reviewers anyway (unchanged).

-- Browse list shows the flag (view is security_invoker, so RLS still filters rows)
create or replace view public.entity_cards with (security_invoker = true) as
  select e.id, e.slug, e.kind, e.name, e.summary,
         e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision,
         e.created_at, e.updated_at,
         public.status_at(e.id, current_date) as current_status,
         a.status as article_status, a.word_count,
         e.is_private, e.published_at
    from public.entities e
    left join public.articles a on a.entity_id = e.id;

-- Imports can create their pages as private drafts
create or replace function public.set_import_privacy(p_batch uuid, p_private boolean)
returns integer
language sql security invoker set search_path = public as $$
  with u as (
    update public.entities e set is_private = p_private
      from public.import_batches b
     where b.id = p_batch and e.id = any (b.created_entity_ids)
    returning e.id
  )
  select count(*)::int from u
$$;
