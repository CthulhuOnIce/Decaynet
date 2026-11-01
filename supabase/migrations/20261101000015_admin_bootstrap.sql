-- =============================================================================
-- Decaynet :: 0015 first-admin bootstrap
--
-- How the first admin comes to exist:
--   'first_signup'  the first account to sign up becomes admin (dev default)
--   'closed'        nobody is promoted automatically; the app server creates
--                   the admin from ADMIN_EMAIL/ADMIN_PASSWORD or through the
--                   /setup wizard (protected by a setup code)
-- The app server switches a fresh site to 'closed' on startup when it holds
-- the service key, so a stranger can't claim a new site by signing up first
-- (even by calling the Auth API directly).
-- =============================================================================

alter table public.site_settings
  add column admin_bootstrap text not null default 'first_signup'
    check (admin_bootstrap in ('first_signup', 'closed'));

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
      when coalesce(v_settings.admin_bootstrap, 'first_signup') = 'first_signup'
       and not exists (select 1 from public.profiles where role = 'admin') then 'admin'
      when not coalesce(v_settings.allow_signups, true) then 'reader'
      else coalesce(v_settings.default_role, 'contributor')
    end
  );
  return new;
end;
$$;

-- Role changes need manage_users, except inside claim_admin() below
create or replace function internal.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.role is distinct from old.role or new.suspended is distinct from old.suspended)
     and current_setting('decaynet.bootstrap', true) is distinct from 'on'
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

-- Promote a user to admin, only while the site has no admin yet.
-- Callable by the service role only (the app server), never by browsers.
create or replace function public.claim_admin(p_user uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.profiles where role = 'admin' and not suspended) then
    raise exception 'This site already has an admin' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'No such user' using errcode = 'P0002';
  end if;
  perform set_config('decaynet.bootstrap', 'on', true);
  update public.profiles set role = 'admin', suspended = false where id = p_user;
end;
$$;
revoke all on function public.claim_admin(uuid) from public, anon, authenticated;
grant execute on function public.claim_admin(uuid) to service_role;

-- Is there an admin yet? (public: drives the /setup redirect)
create or replace function public.site_has_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where role = 'admin' and not suspended)
$$;
