-- =============================================================================
-- Decaynet :: 0002 components
--
-- Each table below is one component type. Rows are temporal facts about an
-- entity (or, for relations, about a pair of entities). Nothing is ever
-- "overwritten" when the world changes: a street renamed in 1968 gets a second
-- name row; a building that burns gets a new lifecycle-state row.
-- =============================================================================

-- Names over time (street renamings, hotel rebrandings, nicknames)
create table public.entity_names (
  like internal.temporal_fact including all,
  entity_id uuid not null references public.entities (id) on delete cascade,
  name text not null,
  name_type text not null default 'official'
    check (name_type in ('official', 'common', 'historic', 'alternate', 'nickname', 'misspelling')),
  language text not null default 'en'
);

-- Shapes over time (footprints, street centerlines, district boundaries, camera viewpoints)
create table public.entity_geometries (
  like internal.temporal_fact including all,
  entity_id uuid not null references public.entities (id) on delete cascade,
  role text not null default 'shape'
    check (role in ('shape', 'footprint', 'centerline', 'point', 'boundary', 'viewpoint')),
  geom extensions.geometry(Geometry, 4326) not null
);

-- Lifecycle over time (active -> vacant -> abandoned -> fire damaged -> demolished)
create table public.entity_states (
  like internal.temporal_fact including all,
  entity_id uuid not null references public.entities (id) on delete cascade,
  status text not null references public.lifecycle_statuses (id)
);

-- Arbitrary keyed attributes over time (floors, architect, population, zoning...)
create table public.entity_attributes (
  like internal.temporal_fact including all,
  entity_id uuid not null references public.entities (id) on delete cascade,
  key text not null references public.attribute_keys (id),
  value jsonb not null
);

-- Street addresses over time. The street is itself an entity, so the rendered
-- address follows street renamings automatically ("577 Washington St" in 1926
-- and whatever that street is called in 2030).
create table public.addresses (
  like internal.temporal_fact including all,
  entity_id uuid not null references public.entities (id) on delete cascade,
  street_id uuid references public.entities (id) on delete set null,
  house_number text,
  unit text,
  postal_code text,
  raw_address text                 -- as printed in the source, verbatim
);

-- Typed, directed edges between entities over time
create table public.relations (
  like internal.temporal_fact including all,
  subject_id uuid not null references public.entities (id) on delete cascade,
  predicate text not null references public.relation_types (id),
  object_id uuid not null references public.entities (id) on delete cascade,
  qualifiers jsonb not null default '{}'::jsonb,   -- {"office": "Mayor"}, {"floor": 2}, {"role": "architect"}
  constraint relation_not_self check (subject_id <> object_id)
);

-- Event-specific component. When = entity lifespan; where = geometry or an
-- "occurred_at" relation.
create table public.event_details (
  entity_id uuid primary key references public.entities (id) on delete cascade,
  event_type text not null references public.event_types (id),
  updated_at timestamptz not null default now()
);

-- Media-specific component. Captured date = entity lifespan start; the camera
-- position is an entity_geometries row with role 'viewpoint'; what it shows is
-- a "depicts" relation whose validity is the time depicted.
create table public.media_items (
  entity_id uuid primary key references public.entities (id) on delete cascade,
  media_type text not null default 'photo' check (media_type in (
    'photo', 'postcard', 'map', 'aerial', 'document', 'newspaper', 'video', 'audio', 'drawing', 'other')),
  storage_path text,               -- object path in the "media" storage bucket
  external_url text,
  mime_type text,
  creator text,
  rights text,                     -- license / rights statement
  bearing smallint check (bearing between 0 and 359),
  source_id uuid references public.sources (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint media_has_file check (storage_path is not null or external_url is not null)
);

-- Historical raster overlays (Sanborn sheets, aerials, plats) with the period they depict
create table public.map_layers (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  tile_url text not null,          -- XYZ template: https://.../{z}/{x}/{y}.png
  tile_size smallint not null default 256,
  attribution text,
  depicts_from date,
  depicts_to date,
  depicts daterange generated always as (daterange(depicts_from, depicts_to, '[]')) stored,
  min_zoom smallint not null default 0,
  max_zoom smallint not null default 22,
  bounds double precision[4],       -- [west, south, east, north]
  default_opacity real not null default 0.75 check (default_opacity between 0 and 1),
  source_id uuid references public.sources (id) on delete set null,
  enabled boolean not null default true,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- Source FKs (not copied by LIKE) + indexes
do $$
declare t text;
begin
  foreach t in array array['entity_names', 'entity_geometries', 'entity_states',
                           'entity_attributes', 'addresses', 'relations'] loop
    execute format(
      'alter table public.%1$I add constraint %1$s_source_fk foreign key (source_id)
         references public.sources (id) on delete set null', t);
    execute format('create index %1$s_valid_idx on public.%1$I using gist (valid)', t);
    execute format('create index %1$s_source_idx on public.%1$I (source_id) where source_id is not null', t);
    execute format('create trigger touch before update on public.%I
         for each row execute function internal.touch_updated_at()', t);
  end loop;
end $$;

create index entity_names_entity_idx on public.entity_names (entity_id);
create index entity_names_trgm_idx on public.entity_names using gin (name extensions.gin_trgm_ops);
create index entity_geometries_entity_idx on public.entity_geometries (entity_id);
create index entity_geometries_geom_idx on public.entity_geometries using gist (geom);
create index entity_states_entity_idx on public.entity_states (entity_id);
create index entity_attributes_entity_idx on public.entity_attributes (entity_id, key);
create index addresses_entity_idx on public.addresses (entity_id);
create index addresses_street_idx on public.addresses (street_id);
create index relations_subject_idx on public.relations (subject_id, predicate);
create index relations_object_idx on public.relations (object_id, predicate);
create index event_details_type_idx on public.event_details (event_type);
create index map_layers_depicts_idx on public.map_layers using gist (depicts);

create trigger touch before update on public.event_details for each row execute function internal.touch_updated_at();
create trigger touch before update on public.media_items for each row execute function internal.touch_updated_at();
