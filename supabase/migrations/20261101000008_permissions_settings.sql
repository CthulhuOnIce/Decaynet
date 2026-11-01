-- =============================================================================
-- Decaynet :: 0008 accounts, permissions, site settings
--
-- Roles are rows, permissions are rows, and the matrix between them is data
-- an admin edits in the app. Every RLS check funnels through has_permission().
-- is_editor() / is_moderator() from 0001 are redefined on top of it, so all
-- earlier policies keep working.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

create table public.permissions (
  id text primary key,
  label text not null,
  description text,
  sort smallint not null default 100
);

create table public.roles (
  id text primary key check (id ~ '^[a-z][a-z0-9_]*$'),
  label text not null,
  description text,
  rank smallint not null default 0,   -- display order / seniority
  builtin boolean not null default false
);

create table public.role_permissions (
  role text not null references public.roles (id) on delete cascade on update cascade,
  permission text not null references public.permissions (id) on delete cascade,
  primary key (role, permission)
);

insert into public.permissions (id, label, description, sort) values
  ('edit_content',    'Edit content',        'Create and edit pages, facts, articles and tag assignments.', 10),
  ('upload_media',    'Upload media',        'Upload photos, scans and other files.', 20),
  ('create_tags',     'Create tags',         'Add new tags and sub-traits to the tag tree.', 30),
  ('review_tips',     'Review tips',         'Read anonymous tips, including any recorded IP data, and process them.', 40),
  ('manage_layers',   'Manage overlays',     'Add and georeference historical map overlays.', 50),
  ('bulk_edit',       'Bulk map tools',      'Retire whole areas and import GeoJSON in the workbench.', 60),
  ('moderate',        'Moderate',            'Delete anyone''s content, lock and feature articles, edit vocabularies.', 70),
  ('manage_users',    'Manage users',        'Change roles and suspend accounts.', 80),
  ('manage_settings', 'Manage site settings','Edit site settings, captcha keys and the permission matrix.', 90);

insert into public.roles (id, label, description, rank, builtin) values
  ('reader',      'Reader',      'Signed in, read-only.', 0, true),
  ('contributor', 'Contributor', 'Adds and edits facts, pages and media.', 10, true),
  ('editor',      'Editor',      'Contributor who also reviews tips, manages overlays and uses bulk tools.', 20, true),
  ('moderator',   'Moderator',   'Cleans up, locks and features articles.', 30, true),
  ('admin',       'Admin',       'Everything, always.', 100, true);

insert into public.role_permissions (role, permission)
select r, p from (values
  ('contributor', 'edit_content'), ('contributor', 'upload_media'), ('contributor', 'create_tags'),
  ('editor', 'edit_content'), ('editor', 'upload_media'), ('editor', 'create_tags'),
  ('editor', 'review_tips'), ('editor', 'manage_layers'), ('editor', 'bulk_edit'),
  ('moderator', 'edit_content'), ('moderator', 'upload_media'), ('moderator', 'create_tags'),
  ('moderator', 'review_tips'), ('moderator', 'manage_layers'), ('moderator', 'bulk_edit'),
  ('moderator', 'moderate')
) v (r, p);

-- Profiles: free-form role (FK instead of check), suspension
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_fk foreign key (role) references public.roles (id) on update cascade,
  add column suspended boolean not null default false,
  add column suspended_reason text,
  add column website text,
  add column last_seen_at timestamptz;

-- -----------------------------------------------------------------------------
-- The one permission check
-- -----------------------------------------------------------------------------
create or replace function public.has_permission(p_permission text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles pr
     where pr.id = auth.uid()
       and not pr.suspended
       and (pr.role = 'admin'
            or exists (select 1 from public.role_permissions rp
                        where rp.role = pr.role and rp.permission = p_permission))
  )
$$;

-- All permissions the current user holds (for the UI)
create or replace function public.my_permissions() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(p.id order by p.sort), '{}')
    from public.permissions p where public.has_permission(p.id)
$$;

create or replace function public.is_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select public.has_permission('edit_content')
$$;

create or replace function public.is_moderator() returns boolean
language sql stable security definer set search_path = public as $$
  select public.has_permission('moderate')
$$;

-- -----------------------------------------------------------------------------
-- Site settings (single row) and server-only secrets
-- -----------------------------------------------------------------------------
create table public.site_settings (
  id boolean primary key default true check (id),
  site_name text not null default 'Decaynet',
  tagline text not null default 'Gary, Indiana through time',
  region_name text not null default 'Gary, Indiana',
  about text not null default '',
  -- map
  map_center_lon double precision not null default -87.3378,
  map_center_lat double precision not null default 41.6012,
  map_zoom real not null default 14,
  default_year integer not null default 1955,
  min_year integer not null default 1890,
  basemap_url text not null default 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  basemap_attribution text not null default '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
  basemap_mode text not null default 'fade' check (basemap_mode in ('fade', 'always', 'hidden')),
  -- accounts
  allow_signups boolean not null default true,
  default_role text not null default 'contributor' references public.roles (id) on update cascade,
  -- tips
  tips_enabled boolean not null default true,
  tips_intro text not null default 'Know something about a building, business, person or event? Tell us. You don''t need an account, and an editor will check it before anything is published.',
  tips_allow_images boolean not null default true,
  tips_max_images smallint not null default 4 check (tips_max_images between 0 and 20),
  tips_max_image_mb smallint not null default 10 check (tips_max_image_mb between 1 and 50),
  tips_ip_mode text not null default 'hash' check (tips_ip_mode in ('off', 'hash', 'full')),
  tips_captcha_provider text not null default 'none' check (tips_captcha_provider in ('none', 'turnstile', 'hcaptcha')),
  tips_captcha_site_key text,
  tips_rate_limit_per_hour smallint not null default 5 check (tips_rate_limit_per_hour between 0 and 1000),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
insert into public.site_settings default values;

create trigger touch before update on public.site_settings
  for each row execute function internal.touch_updated_at();

create table public.site_secrets (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
-- RLS on, no policies: only the service role (server) can read secrets.
alter table public.site_secrets enable row level security;
insert into public.site_secrets (key, value)
values ('ip_hash_salt', encode(extensions.gen_random_bytes(24), 'hex'));

create or replace function public.set_site_secret(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_permission('manage_settings') then
    raise exception 'Only admins can change secrets' using errcode = '42501';
  end if;
  if p_key not in ('tips_captcha_secret', 'ip_hash_salt') then
    raise exception 'Unknown secret %', p_key using errcode = '22023';
  end if;
  if nullif(btrim(p_value), '') is null then
    delete from public.site_secrets where key = p_key;
  else
    insert into public.site_secrets (key, value, updated_at, updated_by)
    values (p_key, btrim(p_value), now(), auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  end if;
end;
$$;

create or replace function public.site_secret_status()
returns table (key text, is_set boolean, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select k.key, s.key is not null, s.updated_at
    from (values ('tips_captcha_secret'), ('ip_hash_salt')) k (key)
    left join public.site_secrets s on s.key = k.key
   where public.has_permission('manage_settings')
$$;

-- New users: role from settings; reader-only when sign-ups are closed; first user is admin
create or replace function internal.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_settings public.site_settings;
begin
  select * into v_settings from public.site_settings where id;
  insert into public.profiles (id, display_name, role)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(new.email, '@', 1), 'anonymous'),
    case
      when not exists (select 1 from public.profiles where role = 'admin') then 'admin'
      when not coalesce(v_settings.allow_signups, true) then 'reader'
      else coalesce(v_settings.default_role, 'contributor')
    end
  );
  return new;
end;
$$;

-- Role / suspension changes need manage_users; nobody can demote the last admin
create or replace function internal.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.role is distinct from old.role or new.suspended is distinct from old.suspended)
     and not public.has_permission('manage_users') then
    raise exception 'Only user managers can change roles or suspensions' using errcode = '42501';
  end if;
  if old.role = 'admin' and (new.role <> 'admin' or new.suspended)
     and (select count(*) from public.profiles where role = 'admin' and not suspended) <= 1 then
    raise exception 'Cannot demote or suspend the last admin' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- RLS for the new tables + tighten a few earlier policies onto permissions
-- -----------------------------------------------------------------------------
alter table public.permissions enable row level security;
alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.site_settings enable row level security;

create policy "read permissions" on public.permissions for select to anon, authenticated using (true);
create policy "read roles" on public.roles for select to anon, authenticated using (true);
create policy "read role_permissions" on public.role_permissions for select to anon, authenticated using (true);
create policy "read site_settings" on public.site_settings for select to anon, authenticated using (true);

create policy "settings managers write roles" on public.roles for all to authenticated
  using ((select public.has_permission('manage_settings'))) with check ((select public.has_permission('manage_settings')));
create policy "settings managers write role_permissions" on public.role_permissions for all to authenticated
  using ((select public.has_permission('manage_settings'))) with check ((select public.has_permission('manage_settings')));
create policy "settings managers update site_settings" on public.site_settings for update to authenticated
  using ((select public.has_permission('manage_settings'))) with check ((select public.has_permission('manage_settings')));

-- Profiles: own profile, or user managers
drop policy "update own profile" on public.profiles;
create policy "update own profile or manage users" on public.profiles for update to authenticated
  using (id = (select auth.uid()) or (select public.has_permission('manage_users')))
  with check (id = (select auth.uid()) or (select public.has_permission('manage_users')));

-- Overlays: manage_layers
drop policy "moderators write map_layers" on public.map_layers;
create policy "layer managers write map_layers" on public.map_layers for all to authenticated
  using ((select public.has_permission('manage_layers'))) with check ((select public.has_permission('manage_layers')));

-- Tags: create_tags
drop policy "contributors create tags" on public.tags;
create policy "tag creators create tags" on public.tags for insert to authenticated
  with check ((select public.has_permission('create_tags')));

-- Storage uploads: upload_media
drop policy "media contributor upload" on storage.objects;
create policy "media uploaders upload" on storage.objects
  for insert to authenticated with check (bucket_id = 'media' and (select public.has_permission('upload_media')));

-- Media rows also require upload_media
drop policy "contributors insert media_items" on public.media_items;
create policy "uploaders insert media_items" on public.media_items for insert to authenticated
  with check ((select public.has_permission('upload_media')));
