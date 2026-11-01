-- =============================================================================
-- Decaynet :: 0001 foundation
--
-- Data-oriented design in one paragraph:
--   An *entity* is nothing but an id + kind + slug. Everything we know about it
--   lives in narrow *component tables* (names, geometries, lifecycle states,
--   attributes, addresses, relations...). Every component row is a *temporal
--   fact*: it carries a validity window with an explicit date precision, a
--   confidence level and an optional citation. *Systems* are SQL functions that
--   fold those facts into a snapshot "as of" a given date (see 0004_systems).
-- =============================================================================

create extension if not exists postgis with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists btree_gist with schema extensions;

create schema if not exists internal;
comment on schema internal is 'Non-exposed helpers: templates, trigger functions.';

-- -----------------------------------------------------------------------------
-- Fuzzy time
-- -----------------------------------------------------------------------------
create type public.date_precision as enum ('day', 'month', 'year', 'decade', 'century', 'unknown');
create type public.confidence_level as enum ('confirmed', 'probable', 'approximate', 'speculative', 'disputed');

-- Snap a date down to the start of its precision window ("1926" @ decade -> 1920-01-01).
create or replace function public.precision_start(d date, p public.date_precision)
returns date language sql immutable parallel safe as $$
  select case
    when d is null then null
    when p = 'month'   then date_trunc('month', d::timestamp)::date
    when p = 'year'    then date_trunc('year', d::timestamp)::date
    when p = 'decade'  then make_date((extract(year from d)::int / 10) * 10, 1, 1)
    when p = 'century' then make_date((extract(year from d)::int / 100) * 100, 1, 1)
    else d
  end
$$;

-- Exclusive end of a precision window ("1975" @ year -> 1976-01-01).
-- This is how "active until 1975" stays true for all of 1975.
create or replace function public.precision_end(d date, p public.date_precision)
returns date language sql immutable parallel safe as $$
  select case
    when d is null then null
    when p = 'month'   then (date_trunc('month', d::timestamp) + interval '1 month')::date
    when p = 'year'    then (date_trunc('year', d::timestamp) + interval '1 year')::date
    when p = 'decade'  then make_date((extract(year from d)::int / 10) * 10 + 10, 1, 1)
    when p = 'century' then make_date((extract(year from d)::int / 100) * 100 + 100, 1, 1)
    else d + 1
  end
$$;

-- Validity window of a fact. NULL bounds mean "unknown / open-ended".
create or replace function public.fuzzy_range(
  from_d date, from_p public.date_precision, to_d date, to_p public.date_precision
) returns daterange language sql immutable parallel safe as $$
  select daterange(public.precision_start(from_d, from_p), public.precision_end(to_d, to_p), '[)')
$$;

-- -----------------------------------------------------------------------------
-- The temporal-fact header. Every component table is created LIKE this one, so
-- all facts share identical time/provenance columns and can be folded by the
-- same systems. (Foreign keys aren't copied by LIKE; each table adds its own.)
-- -----------------------------------------------------------------------------
create table internal.temporal_fact (
  id uuid primary key default gen_random_uuid(),
  valid_from date,
  valid_from_precision public.date_precision not null default 'year',
  valid_to date,
  valid_to_precision public.date_precision not null default 'year',
  valid daterange generated always as (
    public.fuzzy_range(valid_from, valid_from_precision, valid_to, valid_to_precision)
  ) stored,
  confidence public.confidence_level not null default 'probable',
  source_id uuid,
  source_detail text,           -- page number, frame, timestamp, call number...
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint temporal_order check (valid_to is null or valid_from is null or valid_to >= valid_from)
);

-- -----------------------------------------------------------------------------
-- Lookup tables (vocabulary is data, not enums, so the wiki can grow it)
-- -----------------------------------------------------------------------------
create table public.entity_kinds (
  id text primary key,
  label text not null,
  plural text not null,
  color text not null default '#c2562b',
  geometry_hint text check (geometry_hint in ('point', 'line', 'polygon')),
  start_verb text not null default 'Began',   -- timeline wording: "Built", "Born", "Founded"
  end_verb text not null default 'Ended',     -- "Demolished", "Died", "Dissolved"
  description text,
  sort smallint not null default 100
);

create table public.lifecycle_statuses (
  id text primary key,
  label text not null,
  color text not null,
  is_extant boolean not null default true,  -- does a physical thing still stand?
  decay_level smallint not null default 0,  -- 0 healthy .. 5 gone
  description text,
  sort smallint not null default 100
);

create table public.relation_types (
  id text primary key,
  label text not null,             -- subject -> object reading: "occupies"
  inverse_label text not null,     -- object -> subject reading: "occupied by"
  subject_kinds text[],            -- null = any kind
  object_kinds text[],
  description text,
  sort smallint not null default 100
);

create table public.event_types (
  id text primary key,
  label text not null,
  color text not null default '#e0a23a',
  sort smallint not null default 100
);

create table public.attribute_keys (
  id text primary key,
  label text not null,
  value_type text not null default 'text' check (value_type in ('text', 'number', 'year', 'url', 'boolean')),
  unit text,
  applies_to text[],               -- null = any kind
  sort smallint not null default 100
);

create table public.article_statuses (
  id text primary key,
  label text not null,
  color text not null,
  description text,
  moderator_only boolean not null default false,
  sort smallint not null default 100
);

-- -----------------------------------------------------------------------------
-- Sources (citations)
-- -----------------------------------------------------------------------------
create table public.sources (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  kind text not null default 'other' check (kind in (
    'book', 'newspaper', 'periodical', 'website', 'archive', 'map', 'photograph',
    'public_record', 'oral_history', 'directory', 'film', 'other')),
  author text,
  publisher text,
  published_on date,
  published_precision public.date_precision not null default 'year',
  url text,
  archive_url text,
  repository text,                 -- e.g. "Calumet Regional Archives, IU Northwest"
  call_number text,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Entities: identity only (+ lifespan, the one component every entity has)
-- -----------------------------------------------------------------------------
create table public.entities (
  id uuid primary key default gen_random_uuid(),
  kind text not null references public.entity_kinds (id),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null,              -- canonical display name; time-specific names live in entity_names
  summary text,
  exists_from date,
  exists_from_precision public.date_precision not null default 'year',
  exists_to date,
  exists_to_precision public.date_precision not null default 'year',
  lifespan daterange generated always as (
    public.fuzzy_range(exists_from, exists_from_precision, exists_to, exists_to_precision)
  ) stored,
  lifespan_confidence public.confidence_level not null default 'probable',
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lifespan_order check (exists_to is null or exists_from is null or exists_to >= exists_from)
);
comment on column public.entities.exists_from is
  'Built / founded / born / began. For media: date captured. For events: start.';

create index entities_kind_idx on public.entities (kind);
create index entities_lifespan_idx on public.entities using gist (lifespan);
create index entities_name_trgm_idx on public.entities using gin (name extensions.gin_trgm_ops);

-- -----------------------------------------------------------------------------
-- Profiles / roles
-- -----------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  bio text,
  role text not null default 'contributor' check (role in ('reader', 'contributor', 'moderator', 'admin')),
  created_at timestamptz not null default now()
);

create or replace function public.is_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('contributor', 'moderator', 'admin')
  )
$$;

create or replace function public.is_moderator() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('moderator', 'admin')
  )
$$;

-- New auth user -> profile. The very first user becomes admin.
create or replace function internal.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, role)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(new.email, '@', 1), 'anonymous'),
    case when exists (select 1 from public.profiles where role = 'admin') then 'contributor' else 'admin' end
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function internal.handle_new_user();

-- Generic updated_at maintenance
create or replace function internal.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger touch before update on public.entities for each row execute function internal.touch_updated_at();
create trigger touch before update on public.sources for each row execute function internal.touch_updated_at();
