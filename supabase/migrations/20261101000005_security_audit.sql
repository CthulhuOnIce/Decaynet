-- =============================================================================
-- Decaynet :: 0005 security, audit log, storage
--
-- Read: everyone (it's a public wiki).
-- Write: contributors. Delete: moderators, or the contributor who made the row.
-- Vocabulary (lookup tables) and map layers: moderators.
-- Every change to a fact is captured in change_log (record time), which is
-- what powers "Recent changes" and per-entity history alongside the article
-- revision log. Valid time lives on the facts; record time lives here.
-- =============================================================================

create table public.change_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  op text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  row_id uuid,
  entity_id uuid,                 -- deliberately no FK: history outlives deletes
  actor_id uuid default auth.uid(),
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);
create index change_log_entity_idx on public.change_log (entity_id, created_at desc);
create index change_log_created_idx on public.change_log (created_at desc);

create or replace function internal.log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
begin
  -- Geometries are logged as GeoJSON-free summaries to keep the log small
  if tg_table_name = 'entity_geometries' then
    v_old := v_old - 'geom';
    v_new := v_new - 'geom';
  end if;
  v_old := v_old - 'updated_at' - 'valid' - 'lifespan';
  v_new := v_new - 'updated_at' - 'valid' - 'lifespan';

  if tg_op = 'UPDATE' and v_old = v_new and tg_table_name <> 'entity_geometries' then
    return null;
  end if;

  insert into public.change_log (table_name, op, row_id, entity_id, old_data, new_data)
  values (
    tg_table_name,
    tg_op,
    coalesce(v_row ->> 'id', v_row ->> 'entity_id')::uuid,
    case when tg_table_name = 'entities' then (v_row ->> 'id')::uuid
         else coalesce(v_row ->> 'entity_id', v_row ->> 'subject_id')::uuid end,
    v_old,
    v_new
  );
  return null;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['entities', 'entity_names', 'entity_geometries', 'entity_states',
                           'entity_attributes', 'addresses', 'relations', 'event_details',
                           'media_items'] loop
    execute format('create trigger log_change after insert or update or delete on public.%I
                      for each row execute function internal.log_change()', t);
  end loop;
end $$;

-- One feed for "Recent changes": structured edits + prose revisions + status moves
create or replace view public.recent_activity with (security_invoker = true) as
  select 'fact'::text as activity, cl.id::text as id, cl.created_at, cl.actor_id,
         cl.entity_id, cl.table_name as detail, cl.op as action,
         coalesce(cl.new_data, cl.old_data) as data
    from public.change_log cl
  union all
  select 'revision', ar.id::text, ar.created_at, ar.author_id, ar.entity_id,
         ar.edit_summary, 'EDIT', jsonb_build_object('status', ar.status, 'length', length(ar.body))
    from public.article_revisions ar
  union all
  select 'status', se.id::text, se.created_at, se.actor_id, se.entity_id,
         se.note, 'STATUS', jsonb_build_object('from', se.from_status, 'to', se.to_status)
    from public.article_status_events se;

-- -----------------------------------------------------------------------------
-- Row level security
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  -- Content tables: public read, contributor write, moderator-or-owner delete
  foreach t in array array['entities', 'entity_names', 'entity_geometries', 'entity_states',
                           'entity_attributes', 'addresses', 'relations', 'sources'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "read %1$s" on public.%1$I for select to anon, authenticated using (true)', t);
    execute format('create policy "contributors insert %1$s" on public.%1$I for insert to authenticated
                      with check ((select public.is_editor()))', t);
    execute format('create policy "contributors update %1$s" on public.%1$I for update to authenticated
                      using ((select public.is_editor())) with check ((select public.is_editor()))', t);
    execute format('create policy "moderators or owners delete %1$s" on public.%1$I for delete to authenticated
                      using ((select public.is_moderator()) or (created_by = (select auth.uid()) and (select public.is_editor())))', t);
  end loop;

  -- Single-row-per-entity components (no created_by): moderator delete
  foreach t in array array['event_details', 'media_items'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "read %1$s" on public.%1$I for select to anon, authenticated using (true)', t);
    execute format('create policy "contributors insert %1$s" on public.%1$I for insert to authenticated
                      with check ((select public.is_editor()))', t);
    execute format('create policy "contributors update %1$s" on public.%1$I for update to authenticated
                      using ((select public.is_editor())) with check ((select public.is_editor()))', t);
    execute format('create policy "moderators delete %1$s" on public.%1$I for delete to authenticated
                      using ((select public.is_moderator()))', t);
  end loop;

  -- Vocabulary + overlays: public read, moderator write
  foreach t in array array['entity_kinds', 'lifecycle_statuses', 'relation_types', 'event_types',
                           'attribute_keys', 'article_statuses', 'map_layers'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "read %1$s" on public.%1$I for select to anon, authenticated using (true)', t);
    execute format('create policy "moderators write %1$s" on public.%1$I for all to authenticated
                      using ((select public.is_moderator())) with check ((select public.is_moderator()))', t);
  end loop;

  -- Logs: public read, writes only through triggers / functions
  foreach t in array array['change_log', 'article_revisions', 'article_status_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "read %1$s" on public.%1$I for select to anon, authenticated using (true)', t);
  end loop;
end $$;

create policy "contributors write revisions" on public.article_revisions
  for insert to authenticated
  with check (
    (select public.is_editor()) and author_id = (select auth.uid())
    and (not coalesce((select a.locked from public.articles a where a.entity_id = article_revisions.entity_id), false)
         or (select public.is_moderator()))
  );
create policy "contributors write status events" on public.article_status_events
  for insert to authenticated
  with check ((select public.is_editor()) and actor_id = (select auth.uid()));

-- Articles: edits go through save_article(); lock is moderator-only
alter table public.articles enable row level security;
create policy "read articles" on public.articles for select to anon, authenticated using (true);
create policy "contributors update unlocked articles" on public.articles for update to authenticated
  using ((select public.is_editor()) and (not locked or (select public.is_moderator())))
  with check ((select public.is_editor()) and (not locked or (select public.is_moderator())));
create policy "moderators insert articles" on public.articles for insert to authenticated
  with check ((select public.is_moderator()));

create or replace function internal.guard_article_lock() returns trigger
language plpgsql as $$
begin
  if new.locked is distinct from old.locked and not public.is_moderator() then
    raise exception 'Only moderators can lock or unlock articles' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger guard_lock before update on public.articles
  for each row execute function internal.guard_article_lock();

-- Profiles: public read; users edit their own name/bio; admins manage roles
alter table public.profiles enable row level security;
create policy "read profiles" on public.profiles for select to anon, authenticated using (true);
create policy "update own profile" on public.profiles for update to authenticated
  using (id = (select auth.uid()) or (select public.is_moderator()))
  with check (id = (select auth.uid()) or (select public.is_moderator()));

create or replace function internal.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role and not exists (
       select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Only admins can change roles' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger guard_role before update on public.profiles
  for each row execute function internal.guard_profile_role();

-- -----------------------------------------------------------------------------
-- Storage: public "media" bucket, contributors upload
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do nothing;

create policy "media public read" on storage.objects
  for select to anon, authenticated using (bucket_id = 'media');
create policy "media contributor upload" on storage.objects
  for insert to authenticated with check (bucket_id = 'media' and (select public.is_editor()));
create policy "media owner or moderator delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'media' and (owner_id = (select auth.uid())::text or (select public.is_moderator())));

-- Internal helpers are only reached through triggers
revoke all on schema internal from anon, authenticated;
