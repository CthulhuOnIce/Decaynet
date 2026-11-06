-- Records (Admin › Records): edit many pages at once, as of a year and citing a source.
--
-- * change_sets: what an admin is working on (the year or range, the source, how edits land
--   in time). Every change made under one is tagged with it in change_log, so a session's
--   work can be reviewed and undone as a whole.
-- * records_write(): the time-aware writer. One item says "this page's FIELD is VALUE (or
--   isn't), seen in / starting / only during these years"; it works out what to end, start,
--   widen, split or cite so the timeline says exactly that, and never silently cuts a fact
--   that another source backs.
-- * records_delete() / records_undo(): bulk delete, and undoing a change set.

insert into public.permissions (id, label, description, sort) values
  ('manage_records', 'Manage records',
   'Use Admin › Records: edit many pages at once in a table, as of a year and citing a source, and undo whole change sets.', 85)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------------------------
-- Change sets

create table public.change_sets (
  id uuid primary key default gen_random_uuid(),
  title text not null default '',
  actor_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  -- {at, at_p, to, to_p, mode, source_id, source_detail, confidence, conflict}
  context jsonb not null default '{}'::jsonb,
  -- where a "work through" left off, the rows it covers, …
  progress jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  undone_at timestamptz
);
create index change_sets_actor_idx on public.change_sets (actor_id, updated_at desc);
alter table public.change_sets enable row level security;
create policy "record managers read change sets" on public.change_sets for select
  using ((select public.has_permission('manage_records')));
create policy "record managers open change sets" on public.change_sets for insert
  with check ((select public.has_permission('manage_records')) and actor_id = (select auth.uid()));
create policy "record managers update their change sets" on public.change_sets for update
  using ((select public.has_permission('manage_records')) and actor_id = (select auth.uid()));
create policy "record managers delete their change sets" on public.change_sets for delete
  using ((select public.has_permission('manage_records')) and actor_id = (select auth.uid()));
create trigger touch before update on public.change_sets
  for each row execute function internal.touch_updated_at();

alter table public.change_log add column change_set_id uuid references public.change_sets (id) on delete set null;
create index change_log_change_set_idx on public.change_log (change_set_id, id) where change_set_id is not null;
create index change_log_row_idx on public.change_log (row_id, id);

-- What a bulk delete removes that change_log doesn't keep (articles and their revisions, the
-- page's own sources, …), so undoing the change set can put it back.
create table public.records_trash (
  id bigint generated always as identity primary key,
  change_set_id uuid not null references public.change_sets (id) on delete cascade,
  table_name text not null,
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index records_trash_set_idx on public.records_trash (change_set_id, id);
alter table public.records_trash enable row level security;
-- (no policies: only the definer functions below touch it)

-- The change set a write belongs to: set by the records_* functions for their own
-- transaction, or sent by the app as an "x-change-set" request header (any RPC or table
-- write then joins the set). A header naming someone else's set, or an undone one, is ignored.
create or replace function internal.current_change_set() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare
  v text := nullif(current_setting('decaynet.change_set', true), '');
  v_id uuid;
begin
  if v is not null then
    return case when v = '-' then null else v::uuid end;
  end if;
  begin
    v := nullif(current_setting('request.headers', true), '')::json ->> 'x-change-set';
  exception when others then
    v := null;
  end;
  if v is null or v !~* '^[0-9a-f-]{36}$' then
    return null;
  end if;
  select id into v_id from public.change_sets
   where id = v::uuid and actor_id = auth.uid() and undone_at is null;
  return v_id;
end;
$$;
revoke all on function internal.current_change_set() from public;

create or replace function internal.log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_set uuid := internal.current_change_set();
begin
  -- Geometries are logged as GeoJSON-free summaries to keep the log small, except in a
  -- change set, which has to be able to put a shape back
  if tg_table_name = 'entity_geometries' then
    if v_set is null then
      v_old := v_old - 'geom';
      v_new := v_new - 'geom';
    else
      if v_old is not null then v_old := v_old || jsonb_build_object('geom', extensions.st_asewkt(old.geom)); end if;
      if v_new is not null then v_new := v_new || jsonb_build_object('geom', extensions.st_asewkt(new.geom)); end if;
    end if;
  end if;
  v_old := v_old - 'updated_at' - 'valid' - 'lifespan';
  v_new := v_new - 'updated_at' - 'valid' - 'lifespan';

  if tg_op = 'UPDATE' and v_old = v_new and (tg_table_name <> 'entity_geometries' or v_set is not null) then
    return null;
  end if;

  insert into public.change_log (table_name, op, row_id, entity_id, old_data, new_data, change_set_id)
  values (
    tg_table_name,
    tg_op,
    coalesce(v_row ->> 'id', v_row ->> 'entity_id')::uuid,
    case when tg_table_name = 'entities' then (v_row ->> 'id')::uuid
         else coalesce(v_row ->> 'entity_id', v_row ->> 'subject_id')::uuid end,
    v_old,
    v_new,
    v_set
  );
  return null;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Fields: what a records item can set. One row of facts per field, each with a value that
-- compares as jsonb.
--   name            the official name (entity_names)
--   status          the condition (entity_states)
--   address         {street_id, house_number, unit} (addresses)
--   tag             a tag id (entity_tags; several at once)
--   attr:<key>      a fact such as attr:height (entity_attributes)
--   rel:<pred>:out  this page <pred> the value page, e.g. rel:occupies:out on a tenant
--   rel:<pred>:in   the value page <pred> this page, e.g. rel:occupies:in on a building

create or replace function internal.rec_field(p_field text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_parts text[] := string_to_array(coalesce(p_field, ''), ':');
begin
  if p_field = 'name' then
    return jsonb_build_object('tbl', 'entity_names', 'ent', 'entity_id', 'multi', false,
      'val', 'to_jsonb(name)', 'filt', 'name_type = ''official''', 'label', 'name');
  elsif p_field = 'status' then
    return jsonb_build_object('tbl', 'entity_states', 'ent', 'entity_id', 'multi', false,
      'val', 'to_jsonb(status)', 'filt', 'true', 'label', 'condition');
  elsif p_field = 'address' then
    return jsonb_build_object('tbl', 'addresses', 'ent', 'entity_id', 'multi', false,
      'val', 'jsonb_strip_nulls(jsonb_build_object(''street_id'', street_id::text, ''house_number'', nullif(btrim(house_number), ''''), ''unit'', nullif(btrim(unit), '''')))',
      'filt', 'true', 'label', 'address');
  elsif p_field = 'tag' then
    return jsonb_build_object('tbl', 'entity_tags', 'ent', 'entity_id', 'multi', true,
      'val', 'to_jsonb(tag_id::text)', 'filt', 'true', 'label', 'tag');
  elsif v_parts[1] = 'attr' and array_length(v_parts, 1) = 2 then
    if not exists (select 1 from public.attribute_keys where id = v_parts[2]) then
      raise exception 'There''s no fact called “%”', v_parts[2] using errcode = '22023';
    end if;
    return jsonb_build_object('tbl', 'entity_attributes', 'ent', 'entity_id', 'multi', false, 'key', v_parts[2],
      'val', 'value', 'filt', format('key = %L', v_parts[2]),
      'label', (select label from public.attribute_keys where id = v_parts[2]));
  elsif v_parts[1] = 'rel' and array_length(v_parts, 1) = 3 and v_parts[3] in ('out', 'in') then
    if not exists (select 1 from public.relation_types where id = v_parts[2]) then
      raise exception 'There''s no link type “%”', v_parts[2] using errcode = '22023';
    end if;
    return jsonb_build_object('tbl', 'relations', 'multi', true, 'pred', v_parts[2], 'dir', v_parts[3],
      'ent', case when v_parts[3] = 'out' then 'subject_id' else 'object_id' end,
      'val', case when v_parts[3] = 'out' then 'to_jsonb(object_id::text)' else 'to_jsonb(subject_id::text)' end,
      'filt', format('predicate = %L', v_parts[2]),
      'label', (select case when v_parts[3] = 'out' then label else inverse_label end from public.relation_types where id = v_parts[2]));
  end if;
  raise exception 'Unknown field “%”', p_field using errcode = '22023';
end;
$$;

-- The value as the field's rows compare it (and a readable error for a bad one)
create or replace function internal.rec_norm(p_f jsonb, p_value jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v text;
  v_type text;
begin
  if p_value is null or p_value = 'null'::jsonb then
    return null;
  end if;
  if p_f ->> 'tbl' = 'addresses' then
    if jsonb_typeof(p_value) <> 'object' then
      raise exception 'An address needs a street and a number' using errcode = '22023';
    end if;
    p_value := jsonb_strip_nulls(jsonb_build_object(
      'street_id', nullif(btrim(p_value ->> 'street_id'), ''),
      'house_number', nullif(btrim(p_value ->> 'house_number'), ''),
      'unit', nullif(btrim(p_value ->> 'unit'), '')));
    if p_value = '{}'::jsonb then
      return null;
    end if;
    if p_value ? 'street_id' and not exists (select 1 from public.entities where id = (p_value ->> 'street_id')::uuid and kind = 'street') then
      raise exception 'That street isn''t a street page' using errcode = '22023';
    end if;
    return p_value;
  end if;
  v := btrim(regexp_replace(p_value #>> '{}', '\s+', ' ', 'g'));
  if v = '' then
    return null;
  end if;
  if p_f ->> 'tbl' = 'entity_names' then
    return to_jsonb(v);
  elsif p_f ->> 'tbl' = 'entity_states' then
    if not exists (select 1 from public.lifecycle_statuses where id = v) then
      raise exception 'There''s no condition “%”', v using errcode = '22023';
    end if;
    return to_jsonb(v);
  elsif p_f ->> 'tbl' = 'entity_tags' then
    if v !~* '^[0-9a-f-]{36}$' or not exists (select 1 from public.tags where id = v::uuid) then
      raise exception 'There''s no such tag' using errcode = '22023';
    end if;
    return to_jsonb(lower(v));
  elsif p_f ->> 'tbl' = 'relations' then
    if v !~* '^[0-9a-f-]{36}$' or not exists (select 1 from public.entities where id = v::uuid) then
      raise exception 'There''s no such page' using errcode = '22023';
    end if;
    return to_jsonb(lower(v));
  else
    select value_type into v_type from public.attribute_keys where id = p_f ->> 'key';
    if v_type = 'number' then
      v := replace(replace(v, ',', ''), ' ', '');
      if v !~ '^-?\d+(\.\d+)?$' then
        raise exception '% is a number', initcap(p_f ->> 'label') using errcode = '22023';
      end if;
      return to_jsonb(v::numeric);
    end if;
    return to_jsonb(v);
  end if;
end;
$$;

-- A value as people read it
create or replace function internal.rec_value_label(p_f jsonb, p_value jsonb, p_at date) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p_value is null then '(nothing)'
    when p_f ->> 'tbl' = 'addresses' then
      coalesce(public.address_label(p_value ->> 'house_number',
        case when p_value ? 'street_id' then public.name_at((p_value ->> 'street_id')::uuid, coalesce(p_at, current_date)) end, null), '')
      || coalesce(' #' || (p_value ->> 'unit'), '')
    when p_f ->> 'tbl' = 'entity_states' then
      coalesce((select label from public.lifecycle_statuses where id = p_value #>> '{}'), p_value #>> '{}')
    when p_f ->> 'tbl' = 'entity_tags' then
      coalesce((select label from public.tags where id = (p_value #>> '{}')::uuid), '?')
    when p_f ->> 'tbl' = 'relations' then
      coalesce((select public.name_at(id, coalesce(p_at, current_date)) from public.entities where id = (p_value #>> '{}')::uuid), '?')
    when p_f ->> 'tbl' = 'entity_attributes' then
      (p_value #>> '{}') || coalesce(' ' || (select unit from public.attribute_keys where id = p_f ->> 'key'), '')
    else p_value #>> '{}'
  end
$$;

create or replace function internal.rec_span(f date, fp public.date_precision, t date, tp public.date_precision) returns text
language sql immutable as $$
  select case
    when f is null and t is null then 'undated'
    when f is null then 'until ' || public.fuzzy_label(t, tp)
    when t is null then public.fuzzy_label(f, fp) || '–'
    when public.fuzzy_label(f, fp) = public.fuzzy_label(t, tp) then public.fuzzy_label(f, fp)
    else public.fuzzy_label(f, fp) || '–' || public.fuzzy_label(t, tp)
  end
$$;

-- The field's rows for a page, oldest first: {id, f, fp, t, tp, lo, hi, src, v}
-- (lo/hi: the fuzzy range's ends, open ends as -infinity/infinity)
create or replace function internal.rec_rows(p_f jsonb, p_entity uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb;
begin
  execute format(
    'select coalesce(jsonb_agg(jsonb_build_object(''id'', id, ''f'', valid_from, ''fp'', valid_from_precision,
        ''t'', valid_to, ''tp'', valid_to_precision,
        ''lo'', coalesce(lower(valid), ''-infinity''::date), ''hi'', coalesce(upper(valid), ''infinity''::date),
        ''src'', source_id, ''conf'', confidence, ''v'', %s)
        order by lower(valid) nulls first, id), ''[]''::jsonb)
       from public.%I where %I = $1 and %s',
    p_f ->> 'val', p_f ->> 'tbl', p_f ->> 'ent', p_f ->> 'filt')
  using p_entity into v;
  return v;
end;
$$;

create or replace function internal.rec_insert(
  p_f jsonb, p_entity uuid, p_value jsonb,
  f date, fp public.date_precision, t date, tp public.date_precision,
  p_conf public.confidence_level, p_src uuid, p_detail text, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_t text := p_f ->> 'tbl';
begin
  fp := coalesce(fp, 'year');
  tp := coalesce(tp, 'year');
  if v_t = 'entity_names' then
    insert into public.entity_names (entity_id, name, name_type, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail, note)
    values (p_entity, p_value #>> '{}', 'official', f, fp, t, tp, p_conf, p_src, p_detail, p_note) returning id into v_id;
  elsif v_t = 'entity_states' then
    insert into public.entity_states (entity_id, status, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail, note)
    values (p_entity, p_value #>> '{}', f, fp, t, tp, p_conf, p_src, p_detail, p_note) returning id into v_id;
  elsif v_t = 'addresses' then
    insert into public.addresses (entity_id, street_id, house_number, unit, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail, note)
    values (p_entity, (p_value ->> 'street_id')::uuid, p_value ->> 'house_number', p_value ->> 'unit', f, fp, t, tp, p_conf, p_src, p_detail, p_note) returning id into v_id;
  elsif v_t = 'entity_tags' then
    insert into public.entity_tags (entity_id, tag_id, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail, note)
    values (p_entity, (p_value #>> '{}')::uuid, f, fp, t, tp, p_conf, p_src, p_detail, p_note) returning id into v_id;
  elsif v_t = 'entity_attributes' then
    insert into public.entity_attributes (entity_id, key, value, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail, note)
    values (p_entity, p_f ->> 'key', p_value, f, fp, t, tp, p_conf, p_src, p_detail, p_note) returning id into v_id;
  elsif v_t = 'relations' then
    if (p_value #>> '{}')::uuid = p_entity then
      raise exception 'A page can''t be linked to itself' using errcode = '22023';
    end if;
    if exists (select 1 from public.relation_types rt
                where rt.id = p_f ->> 'pred'
                  and ((rt.subject_kinds is not null and not ((select kind from public.entities where id = case when p_f ->> 'dir' = 'out' then p_entity else (p_value #>> '{}')::uuid end) = any (rt.subject_kinds)))
                    or (rt.object_kinds is not null and not ((select kind from public.entities where id = case when p_f ->> 'dir' = 'out' then (p_value #>> '{}')::uuid else p_entity end) = any (rt.object_kinds))))) then
      raise exception 'A % can''t be linked to a % that way',
        (select kind from public.entities where id = case when p_f ->> 'dir' = 'out' then p_entity else (p_value #>> '{}')::uuid end),
        (select kind from public.entities where id = case when p_f ->> 'dir' = 'out' then (p_value #>> '{}')::uuid else p_entity end)
        using errcode = '22023';
    end if;
    insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail, note)
    values (case when p_f ->> 'dir' = 'out' then p_entity else (p_value #>> '{}')::uuid end,
            p_f ->> 'pred',
            case when p_f ->> 'dir' = 'out' then (p_value #>> '{}')::uuid else p_entity end,
            f, fp, t, tp, p_conf, p_src, p_detail, p_note) returning id into v_id;
  end if;
  return v_id;
end;
$$;

-- Give a row a new value in place (a respelling, a correction)
create or replace function internal.rec_set_value(p_f jsonb, p_id uuid, p_value jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_t text := p_f ->> 'tbl';
begin
  if v_t = 'entity_names' then
    update public.entity_names set name = p_value #>> '{}' where id = p_id;
  elsif v_t = 'entity_states' then
    update public.entity_states set status = p_value #>> '{}' where id = p_id;
  elsif v_t = 'addresses' then
    update public.addresses set street_id = (p_value ->> 'street_id')::uuid, house_number = p_value ->> 'house_number', unit = p_value ->> 'unit' where id = p_id;
  elsif v_t = 'entity_tags' then
    update public.entity_tags set tag_id = (p_value #>> '{}')::uuid where id = p_id;
  elsif v_t = 'entity_attributes' then
    update public.entity_attributes set value = p_value where id = p_id;
  elsif v_t = 'relations' then
    if p_f ->> 'dir' = 'out' then
      update public.relations set object_id = (p_value #>> '{}')::uuid where id = p_id;
    else
      update public.relations set subject_id = (p_value #>> '{}')::uuid where id = p_id;
    end if;
  end if;
end;
$$;

-- A copy of a row from a new start (the far side of a split)
create or replace function internal.rec_copy_from(p_tbl text, p_id uuid, f date, fp public.date_precision) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_cols text;
  v_id uuid;
begin
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute
   where attrelid = ('public.' || quote_ident(p_tbl))::regclass and attnum > 0 and not attisdropped
     and attgenerated = '' and attname not in ('id', 'valid_from', 'valid_from_precision', 'created_at', 'updated_at', 'created_by');
  execute format('insert into public.%I (%s, valid_from, valid_from_precision) select %s, $2, $3 from public.%I where id = $1 returning id',
                 p_tbl, v_cols, v_cols, p_tbl)
    using p_id, f, fp into v_id;
  return v_id;
end;
$$;

-- What it takes to keep a different fact D out of a window: nothing ("fine"), end it at the
-- window's start ("trim"), start it after the window ("start"), split it around the window
-- ("split") or remove it ("delete"). cs_* / ce_* are the start and end years of the window
-- (ce null: open-ended, up to the next recorded change, which is left alone).
create or replace function internal.rec_cut_kind(d jsonb, cs_lo date, cs_hi date, ce_lo date, ce_hi date, p_explicit_end boolean)
returns text language plpgsql immutable as $$
declare
  lo date := (d ->> 'lo')::date;
  hi date := (d ->> 'hi')::date;
  v_left boolean;
  v_right boolean;
begin
  if hi <= cs_hi then return 'fine'; end if;                       -- ends during or before the start year
  if ce_lo is not null and lo >= ce_lo then return 'fine'; end if;  -- starts in or after the end year
  if ce_lo is null and lo >= cs_hi then return 'fine'; end if;      -- a later change
  v_left := lo < cs_lo;
  v_right := p_explicit_end and ce_lo is not null and (d ->> 't' is null or hi > ce_hi);
  return case when v_left and v_right then 'split' when v_left then 'trim' when v_right then 'start' else 'delete' end;
end;
$$;

-- Would that cut change what another source says?
create or replace function internal.rec_cut_hurts(d jsonb, p_kind text, p_src uuid) returns boolean
language sql immutable as $$
  select d ->> 'src' is not null and (d ->> 'src')::uuid is distinct from p_src
     and case p_kind
           when 'trim' then d ->> 't' is not null
           when 'start' then d ->> 'f' is not null
           when 'split' then d ->> 't' is not null
           when 'delete' then true
           else false end
$$;

-- ---------------------------------------------------------------------------------------------
-- One item. Returns {entity, field, op, outcome, reason?, steps[]}.
-- outcome: changed | cited | already | skipped | conflict
create or replace function internal.rec_item(p_item jsonb, p_ctx jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_field text := p_item ->> 'field';
  f jsonb := internal.rec_field(p_item ->> 'field');
  v_op text := coalesce(p_item ->> 'op', 'set');
  v_mode text := coalesce(p_item ->> 'mode', p_ctx ->> 'mode', 'seen');
  v_at date := coalesce(p_item ->> 'at', p_ctx ->> 'at')::date;
  v_at_p public.date_precision := coalesce(p_item ->> 'at_p', p_ctx ->> 'at_p', 'year')::public.date_precision;
  v_to date := (case when p_item ? 'at' then p_item ->> 'to' else coalesce(p_item ->> 'to', p_ctx ->> 'to') end)::date;
  v_to_p public.date_precision := coalesce(case when p_item ? 'at' then p_item ->> 'to_p' else coalesce(p_item ->> 'to_p', p_ctx ->> 'to_p') end, 'year')::public.date_precision;
  v_src uuid := (case when p_item ? 'source_id' then p_item ->> 'source_id' else p_ctx ->> 'source_id' end)::uuid;
  v_detail text := nullif(btrim(case when p_item ? 'source_id' then p_item ->> 'source_detail' else coalesce(p_item ->> 'source_detail', p_ctx ->> 'source_detail') end), '');
  v_conf public.confidence_level := coalesce(p_item ->> 'confidence', p_ctx ->> 'confidence', 'probable')::public.confidence_level;
  v_conflict text := coalesce(p_item ->> 'conflict', p_ctx ->> 'conflict', 'skip');
  v_note text := nullif(btrim(coalesce(p_item ->> 'note', p_ctx ->> 'note', '')), '');
  v_entity uuid := (p_item ->> 'entity')::uuid;
  e public.entities;
  v_value jsonb;
  v_rows jsonb;
  r jsonb;
  s jsonb;          -- a row with the same value
  s2 jsonb;
  x jsonb;
  cs_lo date; cs_hi date; ce_lo date; ce_hi date;
  v_explicit boolean;
  v_targets jsonb := '[]';   -- rows to keep out of the window: [{row, kind}]
  v_blockers jsonb;          -- rows that stop a gap being bridged
  v_kind text;
  v_hurts jsonb := '[]';
  v_steps jsonb := '[]';
  v_out jsonb;
  v_new uuid;
  v_new_to date; v_new_to_p public.date_precision;
  v_lbl text;
  v_when text;
  v_bridge boolean;
  v_dispute boolean := false;
  v_srcname text;
begin
  v_out := jsonb_build_object('entity', v_entity, 'field', v_field, 'op', v_op, 'mode', v_mode);
  select * into e from public.entities where id = v_entity;
  if not found then
    return v_out || jsonb_build_object('outcome', 'skipped', 'reason', 'no such page');
  end if;
  v_out := v_out || jsonb_build_object('name', e.name, 'slug', e.slug, 'kind', e.kind);
  if v_op not in ('set', 'add', 'remove') then
    raise exception 'Unknown change “%”', v_op using errcode = '22023';
  end if;
  if v_mode not in ('seen', 'starting', 'only', 'correct') then
    raise exception 'Unknown way to date a change “%”', v_mode using errcode = '22023';
  end if;
  if v_at is null then
    return v_out || jsonb_build_object('outcome', 'skipped', 'reason', 'no year: set one in the context bar');
  end if;
  if v_op = 'add' and not (f ->> 'multi')::boolean then
    v_op := 'set';
  end if;
  v_value := internal.rec_norm(f, p_item -> 'value');
  if v_value is null and v_op <> 'remove' then
    return v_out || jsonb_build_object('outcome', 'skipped', 'reason', 'nothing to set it to');
  end if;
  if v_mode = 'only' and v_to is null then
    return v_out || jsonb_build_object('outcome', 'skipped', 'reason', '“only” needs an end year');
  end if;
  if v_mode = 'starting' then
    v_to := null;
  end if;
  if v_to is not null and public.precision_start(v_to, v_to_p) < public.precision_start(v_at, v_at_p) then
    return v_out || jsonb_build_object('outcome', 'skipped', 'reason', 'the range ends before it starts');
  end if;
  if v_src is null and v_mode <> 'correct' then
    return v_out || jsonb_build_object('outcome', 'skipped', 'reason', 'no source: pick the source you''re working from');
  end if;
  v_srcname := (select title from public.sources where id = v_src);

  cs_lo := public.precision_start(v_at, v_at_p);
  cs_hi := public.precision_end(v_at, v_at_p);
  if v_to is not null then
    ce_lo := public.precision_start(v_to, v_to_p);
    ce_hi := public.precision_end(v_to, v_to_p);
  end if;
  v_when := internal.rec_span(v_at, v_at_p, coalesce(v_to, v_at), case when v_to is null then v_at_p else v_to_p end);
  v_lbl := internal.rec_value_label(f, v_value, v_at);
  v_out := v_out || jsonb_build_object('value_label', v_lbl, 'when', v_when);

  -- not there then: say so rather than give a page facts outside its life
  if v_op <> 'remove' and e.lifespan is not null
     and not (e.lifespan && daterange(cs_lo, coalesce(ce_hi, cs_hi), '[)')) then
    return v_out || jsonb_build_object('outcome', 'skipped',
      'reason', 'not there in ' || v_when || ' (' || internal.rec_span(e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision) || ')');
  end if;

  v_rows := internal.rec_rows(f, v_entity);

  -- ---- remove: keep this value (or any value) out of the window ----
  if v_op = 'remove' then
    if v_mode = 'correct' then
      -- a row that shouldn't be there at all
      for r in select value from jsonb_array_elements(v_rows) loop
        if (v_value is null or r -> 'v' = v_value) and (r ->> 'lo')::date < cs_hi and (r ->> 'hi')::date > cs_lo then
          execute format('delete from public.%I where id = $1', f ->> 'tbl') using (r ->> 'id')::uuid;
          v_steps := v_steps || to_jsonb('removed ' || internal.rec_value_label(f, r -> 'v', v_at) || ' (' || internal.rec_span((r->>'f')::date, (r->>'fp')::public.date_precision, (r->>'t')::date, (r->>'tp')::public.date_precision) || ')');
        end if;
      end loop;
    else
      v_explicit := v_to is not null;
      for r in select value from jsonb_array_elements(v_rows) loop
        if v_value is null or r -> 'v' = v_value then
          v_kind := internal.rec_cut_kind(r, cs_lo, cs_hi, ce_lo, ce_hi, v_explicit);
          if v_kind <> 'fine' then
            v_targets := v_targets || jsonb_build_object('row', r, 'kind', v_kind);
          end if;
        end if;
      end loop;
    end if;
  elsif v_mode = 'correct' then
    -- ---- correct: the row in force then gets the right value; no new history ----
    select value into r from jsonb_array_elements(v_rows) value
     where (value ->> 'lo')::date < cs_hi and (value ->> 'hi')::date > cs_lo
       and (v_op = 'set' or value -> 'v' = v_value)
     order by (value ->> 'lo')::date desc limit 1;
    if r is not null and r -> 'v' = v_value then
      return v_out || jsonb_build_object('outcome', 'already', 'steps', '[]'::jsonb);
    elsif r is not null then
      perform internal.rec_set_value(f, (r ->> 'id')::uuid, v_value);
      return v_out || jsonb_build_object('outcome', 'changed', 'steps',
        jsonb_build_array('corrected ' || internal.rec_value_label(f, r -> 'v', v_at) || ' → ' || v_lbl || ' (' ||
          internal.rec_span((r->>'f')::date, (r->>'fp')::public.date_precision, (r->>'t')::date, (r->>'tp')::public.date_precision) || ')'));
    elsif v_src is null then
      return v_out || jsonb_build_object('outcome', 'skipped', 'reason', 'nothing recorded in ' || v_when || ' to correct; pick a source to add it');
    end if;
    v_mode := 'seen';
  end if;

  if v_op <> 'remove' then
    -- the same value, overlapping the window (or each end of a range)
    select value into s from jsonb_array_elements(v_rows) value
     where value -> 'v' = v_value
       and (value ->> 'lo')::date < cs_hi and (value ->> 'hi')::date > cs_lo
       and (v_mode = 'starting' or ce_lo is null or ((value ->> 'lo')::date < ce_hi and (value ->> 'hi')::date > ce_lo))
     order by (value ->> 'lo')::date limit 1;

    if s is not null then
      -- ---- already so: cite it if it has no source ----
      if s ->> 'src' is null and v_src is not null then
        execute format('update public.%I set source_id = $2, source_detail = $3 where id = $1', f ->> 'tbl')
          using (s ->> 'id')::uuid, v_src, v_detail;
        v_out := v_out || jsonb_build_object('outcome', 'cited', 'steps',
          jsonb_build_array('cited ' || coalesce(v_srcname, 'the source') || ' on ' || v_lbl || ' (' ||
            internal.rec_span((s->>'f')::date, (s->>'fp')::public.date_precision, (s->>'t')::date, (s->>'tp')::public.date_precision) || ')'));
      else
        v_out := v_out || jsonb_build_object('outcome', 'already', 'steps', '[]'::jsonb);
      end if;
      if v_op = 'add' or v_mode = 'starting' then
        return v_out;
      end if;
      -- a set: something else overlapping the window too is cut back (below)
      v_explicit := true;
      if ce_lo is null then ce_lo := cs_lo; ce_hi := cs_hi; end if;
      for r in select value from jsonb_array_elements(v_rows) loop
        if r -> 'v' <> v_value then
          v_kind := internal.rec_cut_kind(r, cs_lo, cs_hi, ce_lo, ce_hi, false);
          if v_kind = 'delete' then
            v_targets := v_targets || jsonb_build_object('row', r, 'kind', v_kind);
          end if;
        end if;
      end loop;
      if jsonb_array_length(v_targets) = 0 then
        return v_out;
      end if;
      v_steps := coalesce(v_out -> 'steps', '[]');
    else
      v_steps := '[]';
      if v_mode = 'starting' then
        -- something else starting that same year is this change, recorded differently
        select value into x from jsonb_array_elements(v_rows) value
         where value -> 'v' <> v_value and value ->> 'f' is not null
           and (value ->> 'lo')::date >= cs_lo and (value ->> 'lo')::date < cs_hi
           and v_op = 'set'
         order by (value ->> 'lo')::date limit 1;
        if x is not null then
          if internal.rec_cut_hurts(x, 'delete', v_src) and v_conflict <> 'trim' then
            return v_out || jsonb_build_object('outcome', 'conflict',
              'reason', 'it''s recorded as ' || internal.rec_value_label(f, x -> 'v', v_at) || ' from ' ||
                internal.rec_span((x->>'f')::date, (x->>'fp')::public.date_precision, (x->>'t')::date, (x->>'tp')::public.date_precision) ||
                ', cited to ' || coalesce((select title from public.sources where id = (x ->> 'src')::uuid), 'another source'));
          end if;
          perform internal.rec_set_value(f, (x ->> 'id')::uuid, v_value);
          if x ->> 'src' is null then
            execute format('update public.%I set source_id = $2, source_detail = $3 where id = $1', f ->> 'tbl')
              using (x ->> 'id')::uuid, v_src, v_detail;
          end if;
          return v_out || jsonb_build_object('outcome', 'changed', 'steps',
            jsonb_build_array('changed ' || internal.rec_value_label(f, x -> 'v', v_at) || ' → ' || v_lbl || ' (' ||
              internal.rec_span((x->>'f')::date, (x->>'fp')::public.date_precision, (x->>'t')::date, (x->>'tp')::public.date_precision) || ')'));
        end if;
        -- up to the next recorded change
        select value into x from jsonb_array_elements(v_rows) value
         where (value ->> 'lo')::date >= cs_hi and (v_op = 'set' or value -> 'v' = v_value)
         order by (value ->> 'lo')::date limit 1;
        v_new_to := (x ->> 'f')::date;
        v_new_to_p := coalesce((x ->> 'fp')::public.date_precision, 'year');
        if x is not null then
          ce_lo := (x ->> 'lo')::date;
          ce_hi := public.precision_end(v_new_to, v_new_to_p);
        end if;
        v_explicit := false;
        v_new := null;
      else
        if v_mode = 'seen' and v_to is null and v_op = 'set' then
          -- something else recorded from this same year, from this source (or none): the same
          -- sighting, entered wrong. Correct it rather than add a second record beside it
          select value into x from jsonb_array_elements(v_rows) value
           where value -> 'v' <> v_value and value ->> 'f' is not null
             and (value ->> 'lo')::date >= cs_lo and (value ->> 'lo')::date < cs_hi
             and (value ->> 'src' is null or (value ->> 'src')::uuid = v_src)
           order by (value ->> 'lo')::date limit 1;
          if x is not null then
            perform internal.rec_set_value(f, (x ->> 'id')::uuid, v_value);
            if x ->> 'src' is null then
              execute format('update public.%I set source_id = $2, source_detail = $3 where id = $1', f ->> 'tbl')
                using (x ->> 'id')::uuid, v_src, v_detail;
            end if;
            return v_out || jsonb_build_object('outcome', 'changed', 'steps',
              jsonb_build_array('corrected ' || internal.rec_value_label(f, x -> 'v', v_at) || ' → ' || v_lbl || ' (' ||
                internal.rec_span((x->>'f')::date, (x->>'fp')::public.date_precision, (x->>'t')::date, (x->>'tp')::public.date_precision) || ')'));
          end if;
        end if;
        -- seen / only: widen a neighbour with the same value when nothing else comes between
        v_bridge := v_mode = 'seen';
        v_blockers := (select coalesce(jsonb_agg(value), '[]') from jsonb_array_elements(v_rows) value
                        where value -> 'v' <> v_value and f ->> 'tbl' <> 'entity_tags');
        -- before: the latest same-valued row ending before the window ends
        select value into s from jsonb_array_elements(v_rows) value
         where value -> 'v' = v_value and (value ->> 'lo')::date < cs_lo and (value ->> 'hi')::date <= coalesce(ce_lo, cs_lo)
         order by (value ->> 'hi')::date desc limit 1;
        if s is not null and not ((s ->> 'hi')::date >= cs_lo or (v_bridge and not exists (
              select 1 from jsonb_array_elements(v_blockers) b
               where (b ->> 'lo')::date < cs_lo and (b ->> 'hi')::date > (s ->> 'hi')::date))) then
          s := null;
        end if;
        -- after: the earliest same-valued row starting after the window
        select value into s2 from jsonb_array_elements(v_rows) value
         where value -> 'v' = v_value and (value ->> 'lo')::date >= cs_hi and (value ->> 'hi')::date > coalesce(ce_hi, cs_hi)
         order by (value ->> 'lo')::date limit 1;
        if s2 is not null and not ((s2 ->> 'lo')::date <= coalesce(ce_hi, cs_hi) or (v_bridge and not exists (
              select 1 from jsonb_array_elements(v_blockers) b
               where (b ->> 'lo')::date < (s2 ->> 'lo')::date and (b ->> 'hi')::date > coalesce(ce_lo, cs_lo)))) then
          s2 := null;
        end if;

        -- the window this value now claims, which other values are kept out of
        v_explicit := true;
        if ce_lo is null then ce_lo := cs_lo; ce_hi := cs_hi; end if;

        if s is null and s2 is null then
          if v_to is null and v_op = 'set' then
            -- one sighting of a single-valued field: it holds up to the next recorded
            -- change, unless what was there has a stated end beyond this year (then just the year)
            if not exists (select 1 from jsonb_array_elements(v_rows) value
                            where value -> 'v' <> v_value and value ->> 't' is not null
                              and (value ->> 'lo')::date < cs_lo and (value ->> 'hi')::date > cs_hi) then
              select value into x from jsonb_array_elements(v_rows) value
               where (value ->> 'lo')::date >= cs_lo and value -> 'v' <> v_value
                 and not ((value ->> 'lo')::date < cs_lo)
               order by (value ->> 'lo')::date limit 1;
              if x is not null then
                v_new_to := (x ->> 'f')::date;
                v_new_to_p := coalesce((x ->> 'fp')::public.date_precision, 'year');
                ce_lo := (x ->> 'lo')::date;
                ce_hi := public.precision_end(v_new_to, v_new_to_p);
                if ce_lo < cs_hi then
                  ce_lo := cs_lo; ce_hi := cs_hi; -- starts that same year: just this year
                end if;
              else
                v_new_to := null;
                ce_lo := null; ce_hi := null;
              end if;
              v_explicit := false;
            else
              v_new_to := v_at; v_new_to_p := v_at_p;
            end if;
          else
            v_new_to := coalesce(v_to, v_at);
            v_new_to_p := case when v_to is null then v_at_p else v_to_p end;
          end if;
        end if;
      end if;

      -- other values in the claimed window
      if v_op = 'set' then
        for r in select value from jsonb_array_elements(v_rows) loop
          if r -> 'v' <> v_value then
            v_kind := internal.rec_cut_kind(r, cs_lo, cs_hi, ce_lo, ce_hi, v_explicit);
            if v_kind <> 'fine' then
              v_targets := v_targets || jsonb_build_object('row', r, 'kind', v_kind);
            end if;
          end if;
        end loop;
      end if;
    end if;
  end if;

  -- ---- would any cut change what another source says? ----
  for x in select value from jsonb_array_elements(v_targets) loop
    if internal.rec_cut_hurts(x -> 'row', x ->> 'kind', v_src) then
      v_hurts := v_hurts || x;
    end if;
  end loop;
  if jsonb_array_length(v_hurts) > 0 then
    if v_conflict = 'skip' or (v_conflict = 'dispute' and v_op = 'remove') then
      x := v_hurts -> 0 -> 'row';
      return v_out || jsonb_build_object('outcome', 'conflict',
        'reason', 'it would ' || case v_hurts -> 0 ->> 'kind' when 'trim' then 'end' when 'start' then 'move the start of' when 'split' then 'split' else 'remove' end
          || ' ' || internal.rec_value_label(f, x -> 'v', v_at) || ' (' ||
          internal.rec_span((x->>'f')::date, (x->>'fp')::public.date_precision, (x->>'t')::date, (x->>'tp')::public.date_precision) ||
          '), cited to ' || coalesce((select title from public.sources where id = (x ->> 'src')::uuid), 'another source'));
    elsif v_conflict = 'dispute' then
      -- leave those as they are; this one goes in alongside, marked disputed
      v_dispute := true;
      v_targets := (select coalesce(jsonb_agg(t), '[]') from jsonb_array_elements(v_targets) t
                     where not internal.rec_cut_hurts(t -> 'row', t ->> 'kind', v_src));
      s := null; s2 := null;
      if v_new_to is null and v_mode <> 'starting' then
        v_new_to := coalesce(v_to, v_at);
        v_new_to_p := case when v_to is null then v_at_p else v_to_p end;
      end if;
    end if;
  end if;

  -- ---- write it ----
  for x in select value from jsonb_array_elements(v_targets) loop
    r := x -> 'row';
    v_kind := x ->> 'kind';
    if v_kind = 'trim' then
      execute format('update public.%I set valid_to = $2, valid_to_precision = $3 where id = $1', f ->> 'tbl')
        using (r ->> 'id')::uuid, v_at, v_at_p;
      v_steps := v_steps || to_jsonb('ended ' || internal.rec_value_label(f, r -> 'v', v_at) || ' (' ||
        internal.rec_span((r->>'f')::date, (r->>'fp')::public.date_precision, (r->>'t')::date, (r->>'tp')::public.date_precision) || ') by ' || public.fuzzy_label(v_at, v_at_p));
    elsif v_kind = 'start' then
      execute format('update public.%I set valid_from = $2, valid_from_precision = $3 where id = $1', f ->> 'tbl')
        using (r ->> 'id')::uuid, coalesce(v_to, v_new_to, v_at), coalesce(case when v_to is null then v_new_to_p end, v_to_p);
      v_steps := v_steps || to_jsonb('moved the start of ' || internal.rec_value_label(f, r -> 'v', v_at) || ' (' ||
        internal.rec_span((r->>'f')::date, (r->>'fp')::public.date_precision, (r->>'t')::date, (r->>'tp')::public.date_precision) || ') to ' ||
        public.fuzzy_label(coalesce(v_to, v_new_to, v_at), coalesce(case when v_to is null then v_new_to_p end, v_to_p)));
    elsif v_kind = 'split' then
      perform internal.rec_copy_from(f ->> 'tbl', (r ->> 'id')::uuid, coalesce(v_to, v_new_to, v_at), coalesce(case when v_to is null then v_new_to_p end, v_to_p, v_at_p));
      execute format('update public.%I set valid_to = $2, valid_to_precision = $3 where id = $1', f ->> 'tbl')
        using (r ->> 'id')::uuid, v_at, v_at_p;
      v_steps := v_steps || to_jsonb('split ' || internal.rec_value_label(f, r -> 'v', v_at) || ' (' ||
        internal.rec_span((r->>'f')::date, (r->>'fp')::public.date_precision, (r->>'t')::date, (r->>'tp')::public.date_precision) || ') around ' || v_when);
    elsif v_kind = 'delete' then
      execute format('delete from public.%I where id = $1', f ->> 'tbl') using (r ->> 'id')::uuid;
      v_steps := v_steps || to_jsonb('removed ' || internal.rec_value_label(f, r -> 'v', v_at) || ' (' ||
        internal.rec_span((r->>'f')::date, (r->>'fp')::public.date_precision, (r->>'t')::date, (r->>'tp')::public.date_precision) || ')');
    end if;
  end loop;

  if v_op <> 'remove' and coalesce(v_out ->> 'outcome', '') not in ('cited', 'already') then
    if s is not null or s2 is not null then
      -- widen the neighbour(s), or add a row of our own between them when they're another source's
      if s is not null and s2 is not null then
        if s ->> 'src' is null or (s ->> 'src')::uuid = v_src then
          execute format('update public.%I set valid_to = $2, valid_to_precision = $3, source_id = coalesce(source_id, $4), source_detail = case when source_id is null then $5 else source_detail end where id = $1', f ->> 'tbl')
            using (s ->> 'id')::uuid, (s2 ->> 'f')::date, (s2 ->> 'fp')::public.date_precision, v_src, v_detail;
          v_steps := v_steps || to_jsonb('carried ' || v_lbl || ' (' || internal.rec_span((s->>'f')::date, (s->>'fp')::public.date_precision, (s->>'t')::date, (s->>'tp')::public.date_precision) || ') on to ' || public.fuzzy_label((s2 ->> 'f')::date, (s2 ->> 'fp')::public.date_precision));
        else
          perform internal.rec_insert(f, v_entity, v_value, (s ->> 't')::date, (s ->> 'tp')::public.date_precision, (s2 ->> 'f')::date, (s2 ->> 'fp')::public.date_precision, v_conf, v_src, v_detail, v_note);
          v_steps := v_steps || to_jsonb('added ' || v_lbl || ' ' || internal.rec_span((s ->> 't')::date, (s ->> 'tp')::public.date_precision, (s2 ->> 'f')::date, (s2 ->> 'fp')::public.date_precision) || ', between the records either side');
        end if;
      elsif s is not null then
        v_new_to := coalesce(v_to, v_at);
        v_new_to_p := case when v_to is null then v_at_p else v_to_p end;
        if s ->> 'src' is null or (s ->> 'src')::uuid = v_src then
          execute format('update public.%I set valid_to = $2, valid_to_precision = $3, source_id = coalesce(source_id, $4), source_detail = case when source_id is null then $5 else source_detail end where id = $1', f ->> 'tbl')
            using (s ->> 'id')::uuid, v_new_to, v_new_to_p, v_src, v_detail;
          v_steps := v_steps || to_jsonb('carried ' || v_lbl || ' (' || internal.rec_span((s->>'f')::date, (s->>'fp')::public.date_precision, (s->>'t')::date, (s->>'tp')::public.date_precision) || ') on to ' || public.fuzzy_label(v_new_to, v_new_to_p));
        else
          perform internal.rec_insert(f, v_entity, v_value, (s ->> 't')::date, (s ->> 'tp')::public.date_precision, v_new_to, v_new_to_p, v_conf, v_src, v_detail, v_note);
          v_steps := v_steps || to_jsonb('added ' || v_lbl || ' ' || internal.rec_span((s ->> 't')::date, (s ->> 'tp')::public.date_precision, v_new_to, v_new_to_p) || ', following on from the record before');
        end if;
      else
        if s2 ->> 'src' is null or (s2 ->> 'src')::uuid = v_src then
          execute format('update public.%I set valid_from = $2, valid_from_precision = $3, source_id = coalesce(source_id, $4), source_detail = case when source_id is null then $5 else source_detail end where id = $1', f ->> 'tbl')
            using (s2 ->> 'id')::uuid, v_at, v_at_p, v_src, v_detail;
          v_steps := v_steps || to_jsonb('started ' || v_lbl || ' (' || internal.rec_span((s2->>'f')::date, (s2->>'fp')::public.date_precision, (s2->>'t')::date, (s2->>'tp')::public.date_precision) || ') from ' || public.fuzzy_label(v_at, v_at_p));
        else
          perform internal.rec_insert(f, v_entity, v_value, v_at, v_at_p, (s2 ->> 'f')::date, (s2 ->> 'fp')::public.date_precision, v_conf, v_src, v_detail, v_note);
          v_steps := v_steps || to_jsonb('added ' || v_lbl || ' ' || internal.rec_span(v_at, v_at_p, (s2 ->> 'f')::date, (s2 ->> 'fp')::public.date_precision) || ', leading up to the record after');
        end if;
      end if;
    else
      if v_op = 'add' and v_mode = 'seen' and v_to is null then
        v_new_to := v_at; v_new_to_p := v_at_p;   -- a sighting of one of several: just that year
      end if;
      perform internal.rec_insert(f, v_entity, v_value, v_at, v_at_p, v_new_to, coalesce(v_new_to_p, 'year'),
        case when v_dispute then 'disputed' else v_conf end, v_src, v_detail, v_note);
      v_steps := v_steps || to_jsonb('added ' || v_lbl || ' ' || internal.rec_span(v_at, v_at_p, v_new_to, coalesce(v_new_to_p, 'year')) ||
        case when v_dispute then ' (disputed: other sources say otherwise)' else '' end);
    end if;
  end if;

  if jsonb_array_length(v_steps) = 0 then
    return v_out || jsonb_build_object('outcome', coalesce(v_out ->> 'outcome', 'already'), 'steps', '[]'::jsonb);
  end if;
  return v_out || jsonb_build_object('outcome', case when v_out ->> 'outcome' = 'cited' and jsonb_array_length(v_steps) = 1 then 'cited' else 'changed' end,
                                     'steps', v_steps);
end;
$$;

-- One item, with a bad one (an unknown condition, a page linked to itself, …) reported
-- as skipped instead of stopping the rest
create or replace function internal.rec_item_safe(p_item jsonb, p_ctx jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  return internal.rec_item(p_item, p_ctx);
exception when sqlstate '22023' or sqlstate '23514' or sqlstate '23503' or sqlstate '23505' or sqlstate '22P02' or sqlstate '22007' or sqlstate '22008' then
  return jsonb_build_object('entity', p_item -> 'entity', 'field', p_item -> 'field', 'op', coalesce(p_item ->> 'op', 'set'),
    'name', (select name from public.entities where id::text = p_item ->> 'entity'),
    'outcome', 'skipped', 'reason', sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- The entry points

create or replace function internal.rec_open_set(p_set uuid) returns public.change_sets
language plpgsql stable security definer set search_path = public as $$
declare
  v public.change_sets;
begin
  if not public.has_permission('manage_records') then
    raise exception 'You need the manage records permission' using errcode = '42501';
  end if;
  select * into v from public.change_sets where id = p_set;
  if not found then
    raise exception 'That change set doesn''t exist' using errcode = '22023';
  end if;
  if v.actor_id is distinct from auth.uid() then
    raise exception 'That change set is someone else''s' using errcode = '42501';
  end if;
  if v.undone_at is not null then
    raise exception 'That change set was undone; start a new one' using errcode = '22023';
  end if;
  return v;
end;
$$;

-- Write a list of items under a change set (its context, overridden per item). With
-- p_preview it works everything out and changes nothing.
-- Returns {items: [...], changed, cited, already, skipped, conflict}
create or replace function public.records_write(p_set uuid, p_items jsonb, p_preview boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_set public.change_sets := internal.rec_open_set(p_set);
  v_ctx jsonb := v_set.context;
  v_results jsonb := '[]';
  it jsonb;
  v_before bigint := (select coalesce(max(id), 0) from public.change_log);
begin
  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Expected a list of changes' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > 5000 then
    raise exception 'That''s more than 5,000 changes at once; split it up' using errcode = '22023';
  end if;
  if p_preview then
    begin
      for it in select value from jsonb_array_elements(p_items) loop
        v_results := v_results || internal.rec_item_safe(it, v_ctx);
      end loop;
      raise exception using errcode = 'DN001', message = 'preview';
    exception when sqlstate 'DN001' then
      null; -- everything above is rolled back; the results stay
    end;
  else
    perform set_config('decaynet.change_set', p_set::text, true);
    for it in select value from jsonb_array_elements(p_items) loop
      v_results := v_results || internal.rec_item_safe(it, v_ctx);
    end loop;
    update public.change_sets set updated_at = now() where id = p_set;
    perform set_config('decaynet.change_set', '', true);
  end if;
  return jsonb_build_object(
    'items', v_results,
    'after', case when p_preview then null else v_before end,
    'changed', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'changed'),
    'cited', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'cited'),
    'already', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'already'),
    'skipped', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'skipped'),
    'conflict', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'conflict'));
end;
$$;
revoke all on function public.records_write(uuid, jsonb, boolean) from public, anon;
grant execute on function public.records_write(uuid, jsonb, boolean) to authenticated;

-- Delete pages in a change set, keeping what change_log doesn't (articles, the page's own
-- sources, external ids, dismissed fixes) so undoing the set brings them back whole.
create or replace function public.records_delete(p_set uuid, p_ids uuid[], p_expect int, p_spaces boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_set public.change_sets := internal.rec_open_set(p_set);
  v_n int;
  v_before bigint := (select coalesce(max(id), 0) from public.change_log);
begin
  select count(*) into v_n from public.entities where id = any (p_ids);
  if p_expect is distinct from v_n then
    raise exception 'Expected to delete % pages, found %', p_expect, v_n using errcode = '22023';
  end if;
  -- and the spaces inside them, at any depth, when asked
  if p_spaces then
    p_ids := p_ids || coalesce((select array_agg(distinct s.id) from unnest(p_ids) b (id), public.interior_spaces(b.id) s), '{}');
    select count(*) into v_n from public.entities where id = any (p_ids);
  end if;
  perform set_config('decaynet.change_set', p_set::text, true);
  insert into public.records_trash (change_set_id, table_name, data)
  select p_set, 'sources', to_jsonb(s) from public.sources s where s.entity_id = any (p_ids)
  union all select p_set, 'article_revisions', to_jsonb(a) from public.article_revisions a where a.entity_id = any (p_ids)
  union all select p_set, 'articles', to_jsonb(a) from public.articles a where a.entity_id = any (p_ids)
  union all select p_set, 'article_status_events', to_jsonb(a) from public.article_status_events a where a.entity_id = any (p_ids)
  union all select p_set, 'entity_external_ids', to_jsonb(a) from public.entity_external_ids a where a.entity_id = any (p_ids)
  union all select p_set, 'timeline_dismissals', to_jsonb(a) from public.timeline_dismissals a where a.entity_id = any (p_ids)
  union all select p_set, 'tips', jsonb_build_object('id', t.id, 'about_entity_id', t.about_entity_id, 'resulting_entity_id', t.resulting_entity_id)
              from public.tips t where t.about_entity_id = any (p_ids) or t.resulting_entity_id = any (p_ids);
  delete from public.entities where id = any (p_ids);
  update public.change_sets set updated_at = now() where id = p_set;
  perform set_config('decaynet.change_set', '', true);
  return jsonb_build_object('deleted', v_n, 'after', v_before);
end;
$$;
revoke all on function public.records_delete(uuid, uuid[], int, boolean) from public, anon;
grant execute on function public.records_delete(uuid, uuid[], int, boolean) to authenticated;

-- The columns a logged row can be put back with
create or replace function internal.rec_cols(p_tbl text, p_data jsonb) returns text
language sql stable security definer set search_path = public as $$
  select string_agg(quote_ident(attname), ', ' order by attnum)
    from pg_attribute
   where attrelid = ('public.' || quote_ident(p_tbl))::regclass and attnum > 0 and not attisdropped
     and attgenerated = '' and p_data ? attname::text
$$;

-- Put a row back as a change_log entry had it before (insert it, or update it if it's there).
-- A page also gets back what records_delete kept aside: its article, its own sources, ….
-- False when what it belongs to isn't back yet.
create or replace function internal.rec_restore(p_table text, p_row uuid, p_data jsonb, p_set uuid) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cols text := internal.rec_cols(p_table, p_data);
  v_key text := case when p_table in ('event_details', 'media_items') then 'entity_id' else 'id' end;
  v_there boolean;
  tr record;
begin
  execute format('select exists (select 1 from public.%I where %I = $1)', p_table, v_key) using p_row into v_there;
  begin
    if v_there then
      execute format('update public.%I set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1)) where %I = $2',
                     p_table, v_cols, v_cols, p_table, v_key) using p_data, p_row;
    else
      execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1)',
                     p_table, v_cols, v_cols, p_table) using p_data;
    end if;
  exception when foreign_key_violation then
    return false;
  end;
  if p_table = 'entities' and not v_there then
    delete from public.articles where entity_id = p_row;  -- the stub a new page gets
    for tr in select * from public.records_trash
               where change_set_id = p_set
                 and (data ->> 'entity_id' = p_row::text or data ->> 'about_entity_id' = p_row::text or data ->> 'resulting_entity_id' = p_row::text)
               order by id loop
      if tr.table_name = 'tips' then
        update public.tips set about_entity_id = coalesce(about_entity_id, (tr.data ->> 'about_entity_id')::uuid),
                               resulting_entity_id = coalesce(resulting_entity_id, (tr.data ->> 'resulting_entity_id')::uuid)
         where id = (tr.data ->> 'id')::uuid;
      else
        v_cols := internal.rec_cols(tr.table_name, tr.data);
        execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1) on conflict do nothing',
                       tr.table_name, v_cols, v_cols, tr.table_name) using tr.data;
      end if;
    end loop;
  end if;
  return true;
end;
$$;
revoke all on function internal.rec_restore(text, uuid, jsonb, uuid) from public;

-- Undo a change set: every row it touched goes back to how it was before the set's first
-- change to it (whatever happened in between, deletes and their undos included). Refuses,
-- listing them, if something outside the set changed one of those rows since; p_preview
-- lists what would be undone. With p_after (the "after" a write returned), only what came
-- after it: undoing the last edit. Returns {undone, conflicts: [...], changes}
create or replace function public.records_undo(p_set uuid, p_preview boolean default false, p_after bigint default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_set public.change_sets := internal.rec_open_set(p_set);
  v_conflicts jsonb;
  v_n int := 0;
  c record;
  v_key text;
  v_later jsonb := '[]';
  v_left jsonb;
  v_round int := 0;
  x jsonb;
begin
  -- rows the set touched that something else changed afterwards
  select coalesce(jsonb_agg(distinct jsonb_build_object('table', l2.table_name, 'row_id', l2.row_id, 'entity_id', l2.entity_id,
           'name', (select name from public.entities where id = l2.entity_id), 'at', l2.created_at)), '[]')
    into v_conflicts
    from (select row_id, max(id) as last_id from public.change_log where change_set_id = p_set and id > coalesce(p_after, 0) group by row_id) mine
    join public.change_log l2 on l2.row_id = mine.row_id and l2.id > mine.last_id
   where l2.change_set_id is distinct from p_set;
  -- and anything added since to a page the set created (undoing it would delete that too)
  select v_conflicts || coalesce(jsonb_agg(distinct jsonb_build_object('table', l2.table_name, 'row_id', l2.row_id, 'entity_id', l2.entity_id,
           'name', (select name from public.entities where id = l2.entity_id), 'at', l2.created_at)), '[]')
    into v_conflicts
    from public.change_log made
    join public.change_log l2 on l2.entity_id = made.row_id and l2.id > made.id and l2.change_set_id is distinct from p_set
   where made.change_set_id = p_set and made.id > coalesce(p_after, 0) and made.table_name = 'entities' and made.op = 'INSERT';
  if jsonb_array_length(v_conflicts) > 0 or p_preview then
    return jsonb_build_object('undone', false, 'conflicts', v_conflicts,
      'changes', (select count(*) from public.change_log where change_set_id = p_set and id > coalesce(p_after, 0)));
  end if;

  -- undoing the whole set isn't part of it; undoing its last edit is (so undoing the whole
  -- set later still comes out right)
  perform set_config('decaynet.change_set', case when p_after is null then '-' else p_set::text end, true);

  -- each row's state before the set first touched it
  select count(distinct (table_name, row_id)) into v_n
    from public.change_log where change_set_id = p_set and id > coalesce(p_after, 0) and row_id is not null;

  -- rows that didn't exist before: gone again (pages last, their own rows go with them)
  for c in select * from (select distinct on (l.table_name, l.row_id) l.table_name, l.row_id, l.op as first_op, l.old_data as before
                    from public.change_log l
                   where l.change_set_id = p_set and l.id > coalesce(p_after, 0) and l.row_id is not null
                   order by l.table_name, l.row_id, l.id) f
            where first_op = 'INSERT' order by (table_name = 'entities'), table_name loop
    v_key := case when c.table_name in ('event_details', 'media_items') then 'entity_id' else 'id' end;
    execute format('delete from public.%I where %I = $1', c.table_name, v_key) using c.row_id;
  end loop;
  -- rows that did: as they were (pages first, links last; a row whose page isn't back yet waits)
  for c in select * from (select distinct on (l.table_name, l.row_id) l.table_name, l.row_id, l.op as first_op, l.old_data as before
                    from public.change_log l
                   where l.change_set_id = p_set and l.id > coalesce(p_after, 0) and l.row_id is not null
                   order by l.table_name, l.row_id, l.id) f
            where first_op <> 'INSERT'
            order by case table_name when 'entities' then 0 when 'relations' then 2 else 1 end, table_name loop
    if not internal.rec_restore(c.table_name, c.row_id, c.before, p_set) then
      v_later := v_later || jsonb_build_object('t', c.table_name, 'r', c.row_id, 'd', c.before);
    end if;
  end loop;
  while jsonb_array_length(v_later) > 0 and v_round < 6 loop
    v_left := '[]';
    for x in select value from jsonb_array_elements(v_later) loop
      if not internal.rec_restore(x ->> 't', (x ->> 'r')::uuid, x -> 'd', p_set) then
        v_left := v_left || x;
      end if;
    end loop;
    v_later := v_left;
    v_round := v_round + 1;
  end loop;
  if jsonb_array_length(v_later) > 0 then
    raise exception 'Couldn''t put back % rows (what they belonged to is gone)', jsonb_array_length(v_later) using errcode = '23503';
  end if;
  if p_after is null then
    update public.change_sets set undone_at = now() where id = p_set;
  end if;
  perform set_config('decaynet.change_set', '', true);
  return jsonb_build_object('undone', true, 'conflicts', '[]'::jsonb, 'changes', v_n);
end;
$$;
revoke all on function public.records_undo(uuid, boolean, bigint) from public, anon;
grant execute on function public.records_undo(uuid, boolean, bigint) to authenticated;

-- My change sets, newest first, with how much is in each
create or replace function public.records_sets(p_limit int default 20)
returns table (id uuid, title text, context jsonb, progress jsonb, created_at timestamptz, updated_at timestamptz,
               undone_at timestamptz, changes bigint, pages bigint)
language sql stable security definer set search_path = public as $$
  select s.id, s.title, s.context, s.progress, s.created_at, s.updated_at, s.undone_at,
         (select count(*) from public.change_log l where l.change_set_id = s.id),
         (select count(distinct l.entity_id) from public.change_log l where l.change_set_id = s.id)
    from public.change_sets s
   where s.actor_id = auth.uid() and public.has_permission('manage_records')
   order by s.updated_at desc
   limit least(greatest(coalesce(p_limit, 20), 1), 200)
$$;
revoke all on function public.records_sets(int) from public, anon;
grant execute on function public.records_sets(int) to authenticated;

-- Addresses typed as text ("512 Broadway", or just "512" on a given street): the street page
-- and number, as records_write takes them. Unknown streets come back without street_id.
create or replace function public.records_addresses(p_texts text[], p_street uuid default null)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(
           case when nullif(btrim(t), '') is null then null
                else jsonb_strip_nulls(jsonb_build_object(
                  'street_id', coalesce(case when sa.street is not null and sa.street <> '' then public.find_street(sa.street) end,
                                        case when sa.street is null or sa.street = '' then p_street end),
                  'house_number', coalesce(sa.house_number, case when btrim(t) ~ '^\d+[a-z]?$' then btrim(t) end),
                  'street', nullif(sa.street, ''),
                  'text', btrim(t))) end
           order by o), '[]'::jsonb)
    from unnest(p_texts) with ordinality u (t, o)
    left join lateral public.split_address(btrim(t)) sa on true
$$;
revoke all on function public.records_addresses(text[], uuid) from public, anon;
grant execute on function public.records_addresses(text[], uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Advanced search, for Records too: these ids, everything inside a building, has spaces, and a
-- light mode (ids and names, up to 5,000) for Records to sort and page itself
create or replace function public.advanced_search(p jsonb)
returns table (
  id uuid, slug text, kind text, name text, name_then text, matched text, matched_in text,
  exists_from date, exists_from_precision public.date_precision, exists_to date, exists_to_precision public.date_precision,
  status text, status_label text, status_color text, article_status text, address text,
  lon double precision, lat double precision, score real, total bigint
)
-- the query is put together from the filters actually asked for (values quoted with %L), so the
-- planner sees plain conditions rather than "the filter is off, or ..." for every one of them
language plpgsql stable security invoker set search_path = public, extensions as $fn$
declare
  q text := nullif(btrim(p ->> 'q'), '');
  v_mode text := coalesce(nullif(p ->> 'match', ''), 'fuzzy');
  v_in text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'in') x), array['names']);
  y0 int := nullif(p ->> 'from_year', '')::int;
  y1 int := nullif(p ->> 'to_year', '')::int;
  v_win daterange;
  v_wsql text := '';
  v_at date := make_date(coalesce(nullif(p ->> 'status_year', '')::int, y1, extract(year from current_date)::int), 7, 1);
  v_dated boolean := y1 is not null;
  w text[] := '{}';
  cand text[] := '{}';
  arr text[];
  pr jsonb := coalesce(p -> 'props', '{}');
  fx jsonb;
  k text;
  v_sort text := coalesce(nullif(p ->> 'sort', ''), 'relevance');
  v_order text;
  -- light: ids and names only, for Records to sort and page itself (up to 5,000)
  v_light boolean := coalesce((p ->> 'light')::boolean, false) and public.has_permission('manage_records');
  v_lim int := least(greatest(coalesce(nullif(p ->> 'limit', '')::int, 50), 1), case when v_light then 5000 else 200 end);
  v_off int := greatest(coalesce(nullif(p ->> 'offset', '')::int, 0), 0);
  v_found text;
  v_street_names constant text := '(select s.name from public.entities s where s.id = x.street_id union all select n.name from public.entity_names n where n.entity_id = x.street_id)';
  v_number constant text := 'substring(coalesce(x.house_number, (public.split_address(x.raw_address)).house_number) from $re$^\d+$re$)::numeric';
  sql text;
  -- "set" / "unset" properties: what having it means
  props constant jsonb := jsonb_build_object(
    'start', 'e.exists_from is not null',
    'end', 'e.exists_to is not null',
    'shape', $p$exists (select 1 from public.entity_geometries g where g.entity_id = e.id and g.role <> 'viewpoint')$p$,
    'address', 'exists (select 1 from public.addresses x where x.entity_id = e.id)',
    'condition', 'exists (select 1 from public.entity_states x where x.entity_id = e.id)',
    'sources', 'exists (select 1 from public.facts f where f.entity_id = e.id and f.source_id is not null)',
    'article', 'coalesce(a.word_count, 0) >= 60',
    'photos', $p$exists (select 1 from public.relations r where r.object_id = e.id and r.predicate = 'depicts')$p$,
    'tags', 'exists (select 1 from public.entity_tags x where x.entity_id = e.id)',
    'links', 'exists (select 1 from public.relations r where r.subject_id = e.id or r.object_id = e.id)',
    'names', 'exists (select 1 from public.entity_names x where x.entity_id = e.id)',
    'spaces', $p$exists (select 1 from public.relations r join public.entities s on s.id = r.subject_id and s.kind = 'space' where r.object_id = e.id and r.predicate = 'part_of')$p$);
begin
  if y0 is not null or y1 is not null then
    v_win := daterange(case when y0 is not null then make_date(y0, 1, 1) end, case when y1 is not null then make_date(y1 + 1, 1, 1) end, '[)');
    v_wsql := format('%L::daterange', v_win);
  end if;

  -- ------------------------------------------------------------------ which pages
  arr := (select array_agg(x) from jsonb_array_elements_text(p -> 'kinds') x);
  if arr is not null then w := w || format('e.kind = any (%L::text[])', arr); end if;
  -- these pages (a selection from the workbench), or everything inside a building
  arr := (select array_agg(x) from jsonb_array_elements_text(p -> 'ids') x);
  if arr is not null then w := w || format('e.id = any (%L::uuid[])', arr); end if;
  if nullif(p ->> 'inside', '') is not null then
    w := w || format('e.id in (select s.id from public.interior_spaces(%L::uuid) s)', (p ->> 'inside')::uuid);
  end if;
  if v_win is not null then w := w || ('e.lifespan && ' || v_wsql); end if;
  if nullif(p #>> '{started,from}', '') is not null then w := w || format('e.exists_from >= %L::date', make_date((p #>> '{started,from}')::int, 1, 1)); end if;
  if nullif(p #>> '{started,to}', '') is not null then w := w || format('e.exists_from < %L::date', make_date((p #>> '{started,to}')::int + 1, 1, 1)); end if;
  if nullif(p #>> '{ended,from}', '') is not null then w := w || format('e.exists_to >= %L::date', make_date((p #>> '{ended,from}')::int, 1, 1)); end if;
  if nullif(p #>> '{ended,to}', '') is not null then w := w || format('e.exists_to < %L::date', make_date((p #>> '{ended,to}')::int + 1, 1, 1)); end if;
  arr := (select array_agg(x) from jsonb_array_elements_text(p -> 'confidences') x);
  if arr is not null then w := w || format('e.lifespan_confidence = any (%L::public.confidence_level[])', arr); end if;
  arr := (select array_agg(x) from jsonb_array_elements_text(p -> 'article_statuses') x);
  if arr is not null then w := w || format('a.status = any (%L::text[])', arr); end if;
  -- the condition in a year, or none recorded then
  arr := (select array_agg(x) from jsonb_array_elements_text(p -> 'statuses') x);
  if arr is not null or coalesce((p ->> 'status_none')::boolean, false) then
    w := w || ('(' || concat_ws(' or ',
      case when arr is not null then format('public.status_at(e.id, %L::date) = any (%L::text[])', v_at, arr) end,
      case when coalesce((p ->> 'status_none')::boolean, false) then format('public.status_at(e.id, %L::date) is null', v_at) end) || ')');
  end if;
  -- tags, with their sub-traits (held within the years, when given)
  arr := (select array_agg(x) from jsonb_array_elements_text(p -> 'tags') x);
  if arr is not null then
    w := w || format('exists (select 1 from public.entity_tags et join public.tag_tree tt on tt.id = et.tag_id where et.entity_id = e.id and tt.ancestor_id = any (%L::uuid[])%s)',
                     arr, case when v_win is not null then ' and et.valid && ' || v_wsql else '' end);
  end if;
  for k in select jsonb_object_keys(pr) loop
    if props ? k and pr ->> k in ('set', 'unset') then
      w := w || ((case when pr ->> k = 'unset' then 'not ' else '' end) || '(' || (props ->> k) || ')');
    end if;
  end loop;
  -- facts: in a range, matching text, or not recorded
  for fx in select * from jsonb_array_elements(coalesce(p -> 'facts', '[]')) loop
    continue when nullif(fx ->> 'key', '') is null;
    if coalesce((fx ->> 'unset')::boolean, false) then
      w := w || format('not exists (select 1 from public.entity_attributes t where t.entity_id = e.id and t.key = %L)', fx ->> 'key');
    else
      w := w || format('exists (select 1 from public.entity_attributes t where t.entity_id = e.id and t.key = %L%s%s%s%s)', fx ->> 'key',
        case when v_win is not null then ' and t.valid && ' || v_wsql else '' end,
        case when nullif(fx ->> 'min', '') is not null then format($m$ and jsonb_typeof(t.value) = 'number' and (t.value #>> '{}')::numeric >= %L::numeric$m$, fx ->> 'min') else '' end,
        case when nullif(fx ->> 'max', '') is not null then format($m$ and jsonb_typeof(t.value) = 'number' and (t.value #>> '{}')::numeric <= %L::numeric$m$, fx ->> 'max') else '' end,
        case when nullif(btrim(fx ->> 'text'), '') is not null then format($m$ and public.search_text_matches(t.value #>> '{}', %L, 'fuzzy')$m$, btrim(fx ->> 'text')) else '' end);
    end if;
  end loop;
  -- an address on a street (any of its names), within house numbers
  if nullif(btrim(p ->> 'street'), '') is not null or nullif(p ->> 'number_from', '') is not null or nullif(p ->> 'number_to', '') is not null then
    w := w || format('exists (select 1 from public.addresses x where x.entity_id = e.id%s%s%s%s)',
      case when v_win is not null then ' and x.valid && ' || v_wsql else '' end,
      case when nullif(btrim(p ->> 'street'), '') is not null then format(
        $m$ and (exists (select 1 from %1$s sn where public.search_text_matches(sn.name, %2$L, 'fuzzy')) or public.search_text_matches((public.split_address(x.raw_address)).street, %2$L, 'fuzzy'))$m$,
        v_street_names, btrim(p ->> 'street')) else '' end,
      case when nullif(p ->> 'number_from', '') is not null then format(' and %s >= %L::numeric', v_number, p ->> 'number_from') else '' end,
      case when nullif(p ->> 'number_to', '') is not null then format(' and %s <= %L::numeric', v_number, p ->> 'number_to') else '' end);
  end if;

  -- ------------------------------------------------------------------ the text
  if q is not null then
    if 'names' = any (v_in) then
      cand := array_append(cand, $c$select b.id, b.name as t, 'name' as how from base b$c$);
      cand := array_append(cand, ($c$select n.entity_id, n.name, 'other name' from public.entity_names n join base b on b.id = n.entity_id$c$
                       || case when v_win is not null then ' where n.valid && ' || v_wsql else '' end));
    end if;
    if 'addresses' = any (v_in) then
      cand := array_append(cand, (format($c$select x.entity_id, coalesce(x.house_number || ' ', '') || sn.name, 'address' from public.addresses x join base b on b.id = x.entity_id join lateral %s sn on true$c$, v_street_names)
                       || case when v_win is not null then ' where x.valid && ' || v_wsql else '' end));
      cand := array_append(cand, ($c$select x.entity_id, x.raw_address, 'address' from public.addresses x join base b on b.id = x.entity_id where x.raw_address is not null$c$
                       || case when v_win is not null then ' and x.valid && ' || v_wsql else '' end));
    end if;
    if 'summary' = any (v_in) then cand := array_append(cand, $c$select b.id, b.summary, 'summary' from base b where b.summary is not null$c$); end if;
    if 'article' = any (v_in) then cand := array_append(cand, $c$select ar.entity_id, ar.body, 'article' from public.articles ar join base b on b.id = ar.entity_id where ar.body <> ''$c$); end if;
    if cardinality(cand) = 0 then cand := array_append(cand, $c$select b.id, b.name as t, 'name' as how from base b$c$); end if;
    -- long texts are searched word for word (a close spelling of a whole article means nothing)
    v_found := format($h$
      select b.*, h.how, h.matched, h.score from base b join (
        select distinct on (c.id) c.id, c.how,
               case when c.how in ('summary', 'article') and length(c.t) > 160
                    then '…' || substr(c.t, greatest(1, position(lower($1) in lower(c.t)) - 60), 160) || '…' else c.t end as matched,
               case when c.how in ('summary', 'article') then 0.4::real else public.search_text_score(c.t, $1) end as score
          from (%s) c (id, t, how)
         where public.search_text_matches(c.t, $1, case when c.how in ('summary', 'article') then %L else %L end)
           -- an address with a house number: the number has to be the same (512 isn't 780 Broadway)
           and (c.how <> 'address' or (public.split_address($1)).house_number is null
                or lower((public.split_address(c.t)).house_number) = lower((public.split_address($1)).house_number))
         order by c.id, 4 desc) h on h.id = b.id$h$,
      array_to_string(cand, ' union all '), case when v_mode = 'fuzzy' then 'contains' else v_mode end, v_mode);
  else
    v_found := 'select b.*, null::text as how, null::text as matched, 0::real as score from base b';
  end if;

  v_order := case v_sort
    when 'name' then 'lower(f.name)'
    when 'start' then 'f.exists_from nulls last, lower(f.name)'
    when 'end' then 'f.exists_to nulls last, lower(f.name)'
    when 'updated' then 'f.updated_at desc nulls last, lower(f.name)'
    else case when q is not null then 'f.score desc, lower(f.name)' else 'lower(f.name)' end end;

  if v_light then
    sql := format($q$
      with base as materialized (
        select e.id, e.slug, e.kind, e.name, e.summary, e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision,
               e.updated_at, a.status as art_status
          from public.entities e left join public.articles a on a.entity_id = e.id
         where %1$s
      ),
      found as (%2$s),
      page as (select f.*, count(*) over () as total from found f order by %3$s limit %4$s offset %5$s)
      select pg.id, pg.slug, pg.kind, pg.name, null::text, pg.matched, pg.how,
             pg.exists_from, pg.exists_from_precision, pg.exists_to, pg.exists_to_precision,
             null::text, null::text, null::text, pg.art_status, null::text, null::float8, null::float8, pg.score::real, pg.total
        from page pg
       order by %6$s
    $q$,
      case when cardinality(w) = 0 then 'true' else array_to_string(w, ' and ') end,
      v_found, v_order, v_lim, v_off, replace(v_order, 'f.', 'pg.'));
    return query execute sql using q, v_at, v_dated;
    return;
  end if;

  sql := format($q$
    with base as materialized (
      select e.id, e.slug, e.kind, e.name, e.summary, e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision,
             e.updated_at, a.status as art_status
        from public.entities e left join public.articles a on a.entity_id = e.id
       where %1$s
    ),
    found as (%2$s),
    page as (select f.*, count(*) over () as total from found f order by %3$s limit %4$s offset %5$s)
    select pg.id, pg.slug, pg.kind, pg.name,
           case when $3 then public.name_at(pg.id, $2) end,
           pg.matched, pg.how,
           pg.exists_from, pg.exists_from_precision, pg.exists_to, pg.exists_to_precision,
           st.id, st.label, st.color, pg.art_status,
           public.address_at(pg.id, $2),
           st_x(st_pointonsurface(gm.g)), st_y(st_pointonsurface(gm.g)),
           pg.score::real, pg.total
      from page pg
      left join public.lifecycle_statuses st on st.id = public.status_at(pg.id, $2)
      left join lateral (select coalesce(public.geometry_at(pg.id, $2), public.locate(pg.id)) as g) gm on true
     order by %6$s
  $q$,
    case when cardinality(w) = 0 then 'true' else array_to_string(w, ' and ') end,
    v_found, v_order, v_lim, v_off, replace(v_order, 'f.', 'pg.'));
  return query execute sql using q, v_at, v_dated;
end;
$fn$;

-- ---------------------------------------------------------------------------------------------
-- Reading: the grid

-- Pages matching advanced-search filters (plus ids / inside), sorted, one page of them with
-- each field's facts in force in the context year. Sorts: advanced search's own, address
-- (street then number), tree (buildings with their spaces under them) and west / east /
-- north / south (by where each page's shape is that year; rows on either side of a street
-- get a side). With ids_only it returns just the ordered ids (for "every matching row").
-- Returns {total, listed, rows: [{id, slug, kind, name, name_then, span, there, parent,
--          spaces, depth, side, shape, cells: {field: [{id, v, label, span, src, src_title, conf, …}]}}]}
create or replace function public.records_grid(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_at date := coalesce(nullif(p ->> 'at', '')::date, current_date);
  v_at_p public.date_precision := coalesce(nullif(p ->> 'at_p', ''), 'year')::public.date_precision;
  v_win daterange;
  v_fields text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(p -> 'fields') x), array['name', 'status', 'address']);
  v_sort text := coalesce(nullif(p ->> 'sort', ''), 'name');
  v_lim int := least(greatest(coalesce(nullif(p ->> 'limit', '')::int, 100), 1), 500);
  v_off int := greatest(coalesce(nullif(p ->> 'offset', '')::int, 0), 0);
  v_total bigint;
  v_ids uuid[];
  v_page uuid[];
  v_side jsonb := '{}';
  v_depth jsonb := '{}';
  v_rows jsonb;
  v_cells jsonb := '{}';
  fld text;
  f jsonb;
  v jsonb;
  v_gaps float8[];
  v_perp float8[];
  v_pid uuid[];
  i int;
  v_big int;
  v_cut float8;
begin
  if not public.has_permission('manage_records') then
    raise exception 'You need the manage records permission' using errcode = '42501';
  end if;
  v_win := daterange(public.precision_start(v_at, v_at_p), public.precision_end(v_at, v_at_p), '[)');

  select array_agg(s.id order by s.ord), max(s.total)
    into v_ids, v_total
    from public.advanced_search((p - 'limit' - 'offset' - 'sort' - 'fields' - 'at' - 'at_p' - 'ids_only')
           || jsonb_build_object('light', true, 'limit', 5000, 'offset', 0,
                'sort', case when v_sort in ('relevance', 'name', 'start', 'end', 'updated') then v_sort else 'name' end))
         with ordinality as s (id, slug, kind, name, name_then, matched, matched_in, ef, efp, et, etp, st, sl, sc, ast, addr, lon, lat, score, total, ord);
  if v_ids is null then
    return jsonb_build_object('total', 0, 'listed', 0, 'rows', '[]'::jsonb, 'ids', '[]'::jsonb);
  end if;

  if v_sort in ('west', 'east', 'north', 'south') then
    -- where each page is that year, then which side of the street (the widest gap across the run)
    with pts as (
      select u.id, u.ord, extensions.st_pointonsurface(coalesce(public.geometry_at(u.id, v_at), public.locate(u.id))) as g
        from unnest(v_ids) with ordinality u (id, ord))
    select array_agg(id order by case v_sort when 'west' then extensions.st_x(g) when 'east' then -extensions.st_x(g)
                                             when 'north' then -extensions.st_y(g) else extensions.st_y(g) end nulls last, ord),
           array_agg(id order by perp) filter (where perp is not null),
           array_agg(perp order by perp) filter (where perp is not null)
      into v_ids, v_pid, v_perp
      from (select pts.*, case when v_sort in ('west', 'east') then extensions.st_y(g) * 111320
                               else extensions.st_x(g) * 111320 * cos(radians(extensions.st_y(g))) end as perp
              from pts) x;
    if coalesce(array_length(v_perp, 1), 0) >= 3 then
      v_gaps := array(select v_perp[k + 1] - v_perp[k] from generate_series(1, array_length(v_perp, 1) - 1) k);
      select k into v_big from generate_series(1, array_length(v_gaps, 1)) k order by v_gaps[k] desc limit 1;
      -- a real split: well clear of every other gap, and at least a narrow street wide
      if v_gaps[v_big] >= 8 and v_gaps[v_big] > 2 * coalesce((select max(g) from unnest(v_gaps) with ordinality t (g, k) where k <> v_big), 0) then
        for i in 1 .. array_length(v_pid, 1) loop
          v_side := v_side || jsonb_build_object(v_pid[i]::text,
            case when v_sort in ('west', 'east') then case when i <= v_big then 'south' else 'north' end
                 else case when i <= v_big then 'west' else 'east' end end);
        end loop;
      end if;
    end if;
  elsif v_sort = 'address' then
    select array_agg(u.id order by a.street nulls last, a.num nulls last, a.hn nulls last, u.ord) into v_ids
      from unnest(v_ids) with ordinality u (id, ord)
      left join lateral (
        select lower(public.name_at(x.street_id, v_at)) as street, substring(x.house_number from '^\d+')::numeric as num, x.house_number as hn
          from public.addresses x where x.entity_id = u.id and x.valid && v_win
         order by lower(x.valid) desc nulls last limit 1) a on true;
  elsif v_sort = 'tree' then
    with recursive chain (id, node, depth, path) as (
      select u.id, u.id, 0, array[lower(e.name) || '|' || e.id::text]
        from unnest(v_ids) u (id) join public.entities e on e.id = u.id
      union all
      select c.id, r.object_id, c.depth + 1, array_prepend(lower(pe.name) || '|' || pe.id::text, c.path)
        from chain c
        join public.relations r on r.subject_id = c.node and r.predicate = 'part_of' and r.valid && v_win
        join public.entities pe on pe.id = r.object_id
       where c.depth < 6
    ), deepest as (select distinct on (id) id, depth, path from chain order by id, depth desc)
    select array_agg(d.id order by d.path, u.ord), jsonb_object_agg(d.id::text, d.depth)
      into v_ids, v_depth
      from deepest d join unnest(v_ids) with ordinality u (id, ord) on u.id = d.id;
  end if;

  if coalesce((p ->> 'ids_only')::boolean, false) then
    return jsonb_build_object('total', v_total, 'listed', cardinality(v_ids), 'ids', to_jsonb(v_ids));
  end if;

  v_page := v_ids[v_off + 1 : v_off + v_lim];
  if cardinality(v_page) = 0 then
    return jsonb_build_object('total', v_total, 'listed', cardinality(v_ids), 'rows', '[]'::jsonb);
  end if;

  -- each field's facts then, one query per field
  foreach fld in array v_fields loop
    begin
      f := internal.rec_field(fld);
    exception when sqlstate '22023' then
      continue;
    end;
    execute format($q$
      select coalesce(jsonb_object_agg(k, vals), '{}'::jsonb) from (
        select t.%1$I::text as k,
               jsonb_agg(jsonb_build_object('id', t.id, 'v', %2$s, 'label', internal.rec_value_label($3, %2$s, $4),
                   'f', t.valid_from, 'fp', t.valid_from_precision, 't', t.valid_to, 'tp', t.valid_to_precision,
                   'span', internal.rec_span(t.valid_from, t.valid_from_precision, t.valid_to, t.valid_to_precision),
                   'src', t.source_id, 'src_title', s.title, 'detail', t.source_detail, 'conf', t.confidence)
                 order by lower(t.valid) desc nulls last) as vals
          from public.%3$I t left join public.sources s on s.id = t.source_id
         where t.%1$I = any ($1) and %4$s and t.valid && $2
         group by 1) x$q$,
      f ->> 'ent', f ->> 'val', f ->> 'tbl', f ->> 'filt')
    using v_page, v_win, f, v_at into v;
    v_cells := v_cells || jsonb_build_object(fld, v);
  end loop;

  select jsonb_agg(jsonb_build_object(
           'id', e.id, 'slug', e.slug, 'kind', e.kind, 'name', e.name, 'private', e.is_private,
           'name_then', public.name_at(e.id, v_at), 'summary', e.summary,
           'from', e.exists_from, 'from_p', e.exists_from_precision, 'to', e.exists_to, 'to_p', e.exists_to_precision,
           'span', internal.rec_span(e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision),
           'there', e.lifespan && v_win,
           'parent', (select jsonb_build_object('id', pe.id, 'slug', pe.slug, 'name', public.name_at(pe.id, v_at))
                        from public.relations r join public.entities pe on pe.id = r.object_id
                       where r.subject_id = e.id and r.predicate = 'part_of'
                       order by (r.valid && v_win) desc, lower(r.valid) desc nulls last limit 1),
           'spaces', (select count(*) from public.relations r where r.object_id = e.id and r.predicate = 'part_of'),
           'depth', coalesce((v_depth ->> e.id::text)::int, 0),
           'side', v_side ->> e.id::text,
           'shape', exists (select 1 from public.entity_geometries g where g.entity_id = e.id and g.role <> 'viewpoint' and g.valid && v_win),
           'cells', (select coalesce(jsonb_object_agg(fl, coalesce(v_cells -> fl -> e.id::text, '[]'::jsonb)), '{}'::jsonb) from unnest(v_fields) fl)
         ) order by u.ord)
    into v_rows
    from unnest(v_page) with ordinality u (id, ord) join public.entities e on e.id = u.id;

  return jsonb_build_object('total', v_total, 'listed', cardinality(v_ids), 'rows', coalesce(v_rows, '[]'::jsonb));
end;
$$;
revoke all on function public.records_grid(jsonb) from public, anon;
grant execute on function public.records_grid(jsonb) to authenticated;

-- Timeless corrections to the pages themselves: title, summary, private, lifespan.
create or replace function public.records_set_pages(p_set uuid, p_ids uuid[], p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_set public.change_sets := internal.rec_open_set(p_set);
  v_sets text[] := '{}';
  v_n int;
  k text;
  v_before bigint := (select coalesce(max(id), 0) from public.change_log);
begin
  for k in select jsonb_object_keys(p_patch) loop
    if k = 'name' then
      if nullif(btrim(p_patch ->> k), '') is null then
        raise exception 'A page needs a title' using errcode = '22023';
      end if;
      v_sets := array_append(v_sets, format('name = %L', btrim(regexp_replace(p_patch ->> k, '\s+', ' ', 'g'))));
    elsif k = 'summary' then
      v_sets := array_append(v_sets, format('summary = %L', nullif(btrim(p_patch ->> k), '')));
    elsif k = 'is_private' then
      v_sets := array_append(v_sets, format('is_private = %L', (p_patch ->> k)::boolean));
    elsif k in ('exists_from', 'exists_to') then
      v_sets := array_append(v_sets, format('%I = %L::date', k, nullif(p_patch ->> k, '')));
    elsif k in ('exists_from_precision', 'exists_to_precision') then
      v_sets := array_append(v_sets, format('%I = %L::public.date_precision', k, p_patch ->> k));
    elsif k = 'lifespan_confidence' then
      v_sets := array_append(v_sets, format('lifespan_confidence = %L::public.confidence_level', p_patch ->> k));
    else
      raise exception 'Records can''t change “%” here', k using errcode = '22023';
    end if;
  end loop;
  if cardinality(v_sets) = 0 then
    return jsonb_build_object('changed', 0);
  end if;
  perform set_config('decaynet.change_set', p_set::text, true);
  execute format('update public.entities set %s where id = any ($1)', array_to_string(v_sets, ', ')) using p_ids;
  get diagnostics v_n = row_count;
  update public.change_sets set updated_at = now() where id = p_set;
  perform set_config('decaynet.change_set', '', true);
  return jsonb_build_object('changed', v_n, 'after', v_before);
end;
$$;
revoke all on function public.records_set_pages(uuid, uuid[], jsonb) from public, anon;
grant execute on function public.records_set_pages(uuid, uuid[], jsonb) to authenticated;


-- ---------------------------------------------------------------------------------------------
-- Workflow tools

-- A slug for a new page: its parent's slug (for a space) or nothing, then the name.
create or replace function internal.rec_new_slug(p_prefix text, p_name text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  v text := coalesce(nullif(trim(both '-' from regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g')), ''), 'page');
begin
  if p_prefix is not null then v := p_prefix || '-' || v; end if;
  v := left(v, 90);
  while exists (select 1 from public.entities where slug = v) loop
    v := regexp_replace(v, '-[0-9a-f]{4}$', '') || '-' || substr(md5(random()::text), 1, 4);
  end loop;
  return v;
end;
$$;
revoke all on function internal.rec_new_slug(text, text) from public;

-- The context's dates as a claim: from (at), to (only: to; otherwise open)
create or replace function internal.rec_ctx_span(p_ctx jsonb, out f date, out fp public.date_precision, out t date, out tp public.date_precision)
language sql immutable as $$
  select (p_ctx ->> 'at')::date, coalesce(p_ctx ->> 'at_p', 'year')::public.date_precision,
         case when p_ctx ->> 'mode' = 'only' then (p_ctx ->> 'to')::date end,
         coalesce(case when p_ctx ->> 'mode' = 'only' then p_ctx ->> 'to_p' end, 'year')::public.date_precision
$$;

-- Stub spaces into a building, as seen in the context year: no shape yet (draw them in the
-- workbench later). Each row: {name, first_name?, unit?, floor?, address?, tenant?}. Dated
-- and cited from the change set; a tenant is linked as seen that year.
-- Returns {added: [{id, slug, name}], items: [results of the tenant links]}
create or replace function public.records_add_spaces(p_set uuid, p_building uuid, p_rows jsonb, p_preview boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_set public.change_sets := internal.rec_open_set(p_set);
  c jsonb := v_set.context;
  b public.entities;
  s record;
  r jsonb;
  v_id uuid;
  v_slug text;
  v_name text;
  v_first text;
  v_src uuid := (c ->> 'source_id')::uuid;
  v_detail text := nullif(btrim(c ->> 'source_detail'), '');
  v_conf public.confidence_level := coalesce(c ->> 'confidence', 'probable')::public.confidence_level;
  v_added jsonb := '[]';
  v_items jsonb := '[]';
  v_addr record;
  v_street uuid;
  v_out jsonb;
  v_before bigint := (select coalesce(max(id), 0) from public.change_log);
begin
  select * into b from public.entities where id = p_building;
  if not found or b.kind not in ('building', 'site', 'space') then
    raise exception 'Spaces go in a building, a site or another space' using errcode = '22023';
  end if;
  if c ->> 'at' is null or v_src is null then
    raise exception 'Set the year and the source you''re working from first' using errcode = '22023';
  end if;
  select * into s from internal.rec_ctx_span(c);
  if not p_preview then
    perform set_config('decaynet.change_set', p_set::text, true);
  end if;
  begin
    for r in select value from jsonb_array_elements(p_rows) loop
      v_name := nullif(btrim(regexp_replace(coalesce(r ->> 'name', ''), '\s+', ' ', 'g')), '');
      continue when v_name is null;
      v_slug := internal.rec_new_slug(b.slug, v_name);
      insert into public.entities (kind, slug, name, exists_from, exists_from_precision, exists_to, exists_to_precision, lifespan_confidence)
      values ('space', v_slug, v_name, s.f, s.fp, s.t, s.tp, v_conf) returning id into v_id;
      insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail)
      values (v_id, 'part_of', p_building, s.f, s.fp, s.t, s.tp, v_conf, v_src, v_detail);
      if nullif(btrim(r ->> 'unit'), '') is not null then
        insert into public.entity_attributes (entity_id, key, value, valid_from, valid_from_precision, source_id, source_detail)
        values (v_id, 'unit_label', to_jsonb(btrim(r ->> 'unit')), s.f, s.fp, v_src, v_detail);
      end if;
      if nullif(btrim(r ->> 'floor'), '') ~ '^-?\d+(\.\d+)?$' then
        insert into public.entity_attributes (entity_id, key, value, valid_from, valid_from_precision, source_id, source_detail)
        values (v_id, 'floor', to_jsonb((r ->> 'floor')::numeric), s.f, s.fp, v_src, v_detail);
      end if;
      v_first := nullif(btrim(regexp_replace(coalesce(r ->> 'first_name', ''), '\s+', ' ', 'g')), '');
      if v_first is not null and lower(v_first) <> lower(v_name) then
        insert into public.entity_names (entity_id, name, name_type, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail)
        values (v_id, v_first, 'official', s.f, s.fp, s.t, s.tp, v_conf, v_src, v_detail);
      end if;
      if nullif(btrim(r ->> 'address'), '') is not null then
        select * into v_addr from public.split_address(btrim(r ->> 'address'));
        v_street := case when coalesce(v_addr.street, '') <> '' then public.find_street(v_addr.street)
                         else (select a.street_id from public.addresses a where a.entity_id = p_building and a.valid @> s.f order by a.valid_from desc nulls last limit 1) end;
        insert into public.addresses (entity_id, street_id, house_number, unit, raw_address, valid_from, valid_from_precision, valid_to, valid_to_precision, confidence, source_id, source_detail)
        values (v_id, v_street, coalesce(v_addr.house_number, case when btrim(r ->> 'address') ~ '^\d+[a-z]?$' then btrim(r ->> 'address') end),
                nullif(btrim(r ->> 'unit'), ''), case when v_street is null then btrim(r ->> 'address') end, s.f, s.fp, s.t, s.tp, v_conf, v_src, v_detail);
      end if;
      v_added := v_added || jsonb_build_object('id', v_id, 'slug', v_slug, 'name', v_name);
      if nullif(r ->> 'tenant', '') is not null then
        v_items := v_items || internal.rec_item_safe(jsonb_build_object('entity', v_id, 'field', 'rel:occupies:in', 'op', 'add', 'value', r ->> 'tenant'), c);
      end if;
    end loop;
    if p_preview then
      raise exception using errcode = 'DN001', message = 'preview';
    end if;
  exception when sqlstate 'DN001' then
    null;
  end;
  if not p_preview then
    update public.change_sets set updated_at = now() where id = p_set;
    perform set_config('decaynet.change_set', '', true);
  end if;
  return jsonb_build_object('added', v_added, 'items', v_items, 'after', case when p_preview then null else v_before end);
end;
$$;
revoke all on function public.records_add_spaces(uuid, uuid, jsonb, boolean) from public, anon;
grant execute on function public.records_add_spaces(uuid, uuid, jsonb, boolean) to authenticated;

-- The names on these pages that match a text (any name they ever had), with their dates
create or replace function public.records_name_matches(p_ids uuid[], p_match text)
returns table (entity_id uuid, name_id uuid, name text, name_type text, valid_from date, valid_from_precision public.date_precision,
               valid_to date, valid_to_precision public.date_precision, source_id uuid, source_detail text, is_title boolean)
language sql stable security definer set search_path = public as $$
  select n.entity_id, n.id, n.name, n.name_type, n.valid_from, n.valid_from_precision, n.valid_to, n.valid_to_precision,
         n.source_id, n.source_detail, false
    from public.entity_names n
   where n.entity_id = any (p_ids) and public.has_permission('manage_records')
     and public.search_text_matches(n.name, p_match, 'fuzzy')
  union all
  -- the page title, when no dated name matches: the page's own dates
  select e.id, null, e.name, 'title', e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision, null, null, true
    from public.entities e
   where e.id = any (p_ids) and public.has_permission('manage_records')
     and public.search_text_matches(e.name, p_match, 'fuzzy')
     and not exists (select 1 from public.entity_names n where n.entity_id = e.id and public.search_text_matches(n.name, p_match, 'fuzzy'))
$$;
revoke all on function public.records_name_matches(uuid[], text) from public, anon;
grant execute on function public.records_name_matches(uuid[], text) to authenticated;

-- An item dated like a name: only its years when it has an end, from its start when it
-- doesn't, seen in the context year when it has no dates at all
create or replace function internal.rec_item_from_name(
  p_entity uuid, f date, fp public.date_precision, t date, tp public.date_precision, p_src uuid, p_detail text,
  p_field text, p_value jsonb, p_ctx jsonb, p_cite_names boolean
) returns jsonb
language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'entity', p_entity, 'field', p_field, 'op', 'add', 'value', p_value,
    'mode', case when f is null then 'seen' when t is null then 'starting' else 'only' end,
    'at', coalesce(f, (p_ctx ->> 'at')::date), 'at_p', case when f is null then coalesce(p_ctx ->> 'at_p', 'year') else fp::text end,
    'to', t, 'to_p', tp)
    || case when p_cite_names and p_src is not null then jsonb_build_object('source_id', p_src, 'source_detail', p_detail) else '{}'::jsonb end)
$$;

-- Workflow 1: an organization for something that only existed as named spaces. Finds each
-- space's names that match, links the organization as their tenant for those years (cited
-- to the names' own sources, or the context's), optionally renames those name records to
-- the space's unit, and widens the organization's lifespan to its tenancies.
-- p_org: an existing page, or null with p_new {name, kind} to create one.
-- p_opts: {dates: names|context, sources: names|context, rename: keep|unit|remove, widen: bool}
create or replace function public.records_make_tenant(p_set uuid, p_ids uuid[], p_match text, p_org uuid, p_new jsonb, p_opts jsonb, p_preview boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_set public.change_sets := internal.rec_open_set(p_set);
  c jsonb := v_set.context;
  v_org uuid := p_org;
  o public.entities;
  m record;
  it jsonb;
  v_results jsonb := '[]';
  v_steps jsonb := '[]';
  v_names_dates boolean := coalesce(p_opts ->> 'dates', 'names') = 'names';
  v_cite_names boolean := coalesce(p_opts ->> 'sources', 'names') = 'names';
  v_rename text := coalesce(p_opts ->> 'rename', 'keep');
  v_unit text;
  v_lo date; v_lo_p public.date_precision; v_hi date; v_hi_p public.date_precision; v_open boolean;
  v_before bigint := (select coalesce(max(id), 0) from public.change_log);
  v_new_name text := nullif(btrim(p_new ->> 'name'), '');
begin
  if nullif(btrim(p_match), '') is null then
    raise exception 'What name are you looking for?' using errcode = '22023';
  end if;
  if not p_preview then
    perform set_config('decaynet.change_set', p_set::text, true);
  end if;
  begin
    if v_org is null then
      if v_new_name is null then
        raise exception 'Pick the organization, or name a new one' using errcode = '22023';
      end if;
      insert into public.entities (kind, slug, name, is_private)
      values (coalesce(nullif(p_new ->> 'kind', ''), 'organization'), internal.rec_new_slug(null, v_new_name), v_new_name, coalesce((p_new ->> 'private')::boolean, false))
      returning id into v_org;
      v_steps := v_steps || to_jsonb('made the page ' || v_new_name);
    end if;
    select * into o from public.entities where id = v_org;

    for m in select * from public.records_name_matches(p_ids, p_match) order by entity_id, valid_from nulls first loop
      if v_names_dates then
        it := internal.rec_item_from_name(m.entity_id, m.valid_from, m.valid_from_precision, m.valid_to, m.valid_to_precision, m.source_id, m.source_detail,
                                         'rel:occupies:in', to_jsonb(v_org::text), c, v_cite_names);
      else
        it := jsonb_build_object('entity', m.entity_id, 'field', 'rel:occupies:in', 'op', 'add', 'value', v_org::text)
              || case when v_cite_names and m.source_id is not null then jsonb_build_object('source_id', m.source_id, 'source_detail', m.source_detail) else '{}'::jsonb end;
      end if;
      if p_opts ? 'conflict' then
        it := it || jsonb_build_object('conflict', p_opts ->> 'conflict');
      end if;
      v_results := v_results || (internal.rec_item_safe(it, c) || jsonb_build_object('matched', m.name));
      -- the name was really the tenant's: the space goes by its unit (or "Storefront") then, or loses that name
      if v_rename <> 'keep' and not m.is_title and m.name_id is not null then
        if v_rename = 'remove' then
          delete from public.entity_names where id = m.name_id;
        else
          v_unit := coalesce((select a.value #>> '{}' from public.entity_attributes a where a.entity_id = m.entity_id and a.key = 'unit_label' order by a.valid_from desc nulls last limit 1), 'Storefront');
          update public.entity_names set name = v_unit where id = m.name_id;
        end if;
      end if;
    end loop;

    if coalesce((p_opts ->> 'widen')::boolean, true) then
      -- the organization's lifespan covers its tenancies
      select r.valid_from, r.valid_from_precision into v_lo, v_lo_p from public.relations r
       where r.subject_id = v_org and r.predicate = 'occupies' order by lower(r.valid) nulls first limit 1;
      select bool_or(r.valid_to is null) into v_open from public.relations r where r.subject_id = v_org and r.predicate = 'occupies';
      select r.valid_to, r.valid_to_precision into v_hi, v_hi_p from public.relations r
       where r.subject_id = v_org and r.predicate = 'occupies' and r.valid_to is not null order by upper(r.valid) desc limit 1;
      if v_lo is not null and (o.exists_from is null or v_lo < o.exists_from) then
        update public.entities set exists_from = v_lo, exists_from_precision = v_lo_p where id = v_org;
        v_steps := v_steps || to_jsonb('started ' || o.name || ' ' || public.fuzzy_label(v_lo, v_lo_p));
      end if;
      if not coalesce(v_open, true) and v_hi is not null and o.exists_to is not null and v_hi > o.exists_to then
        update public.entities set exists_to = v_hi, exists_to_precision = v_hi_p where id = v_org;
        v_steps := v_steps || to_jsonb('ended ' || o.name || ' ' || public.fuzzy_label(v_hi, v_hi_p));
      end if;
    end if;
    if p_preview then
      raise exception using errcode = 'DN001', message = 'preview';
    end if;
  exception when sqlstate 'DN001' then
    null;
  end;
  if not p_preview then
    update public.change_sets set updated_at = now() where id = p_set;
    perform set_config('decaynet.change_set', '', true);
  end if;
  return jsonb_build_object(
    'org', jsonb_build_object('id', case when p_preview and p_org is null then null else v_org end, 'slug', o.slug, 'name', coalesce(o.name, v_new_name)),
    'steps', v_steps, 'items', v_results, 'after', case when p_preview then null else v_before end,
    'changed', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'changed'),
    'cited', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'cited'),
    'already', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'already'),
    'skipped', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'skipped'),
    'conflict', (select count(*) from jsonb_array_elements(v_results) r where r ->> 'outcome' = 'conflict'));
end;
$$;
revoke all on function public.records_make_tenant(uuid, uuid[], text, uuid, jsonb, jsonb, boolean) from public, anon;
grant execute on function public.records_make_tenant(uuid, uuid[], text, uuid, jsonb, jsonb, boolean) to authenticated;

-- Tags a page's names suggest: a tag whose label (or its singular) appears as a word in one
-- of its names ("Joe's Tavern" → Tavern), dated like that name. Leaves out what's tagged then.
-- Returns [{entity, tag_id, tag, path, name, item}] (item: ready for records_write)
create or replace function public.records_tag_suggestions(p_set uuid, p_ids uuid[])
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_set public.change_sets := internal.rec_open_set(p_set);
  c jsonb := v_set.context;
  v jsonb := '[]';
  m record;
begin
  for m in
    with names as (
      select n.entity_id, n.id as name_id, n.name, n.name_type, n.valid_from, n.valid_from_precision, n.valid_to, n.valid_to_precision,
             n.source_id, n.source_detail, false as is_title
        from public.entity_names n where n.entity_id = any (p_ids)
      union all
      select e.id, null, e.name, 'title', e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision, null, null, true
        from public.entities e where e.id = any (p_ids)
    ), words as (
      select t.id as tag_id, t.label, ti.path, lower(t.label) as w,
             lower(regexp_replace(t.label, '(ies|s)$', case when t.label ~* 'ies$' then 'y' else '' end, 'i')) as w1
        from public.tags t join public.tag_index ti on ti.id = t.id
       where length(t.label) >= 3
    )
    select distinct on (nm.entity_id, w.tag_id) nm.*, w.tag_id, w.label, w.path
      from names nm join words w
        on lower(nm.name) ~ ('(^|[^a-z])(' || regexp_replace(w.w, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '|' ||
                             regexp_replace(w.w1, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || ')s?($|[^a-z])')
     where not exists (select 1 from public.entity_tags et where et.entity_id = nm.entity_id and et.tag_id = w.tag_id
                         and (nm.valid_from is null or et.valid && public.fuzzy_range(nm.valid_from, nm.valid_from_precision, nm.valid_to, nm.valid_to_precision)))
     order by nm.entity_id, w.tag_id, nm.is_title, nm.valid_from nulls last
  loop
    v := v || jsonb_build_object('entity', m.entity_id, 'tag_id', m.tag_id, 'tag', m.label, 'path', m.path, 'name', m.name,
      'when', internal.rec_span(m.valid_from, m.valid_from_precision, m.valid_to, m.valid_to_precision),
      'item', internal.rec_item_from_name(m.entity_id, m.valid_from, m.valid_from_precision, m.valid_to, m.valid_to_precision, m.source_id, m.source_detail,
                                         'tag', to_jsonb(m.tag_id::text), c, true));
  end loop;
  return v;
end;
$$;
revoke all on function public.records_tag_suggestions(uuid, uuid[]) from public, anon;
grant execute on function public.records_tag_suggestions(uuid, uuid[]) to authenticated;

revoke all on function internal.rec_field(text) from public;
revoke all on function internal.rec_norm(jsonb, jsonb) from public;
revoke all on function internal.rec_value_label(jsonb, jsonb, date) from public;
revoke all on function internal.rec_rows(jsonb, uuid) from public;
revoke all on function internal.rec_insert(jsonb, uuid, jsonb, date, public.date_precision, date, public.date_precision, public.confidence_level, uuid, text, text) from public;
revoke all on function internal.rec_set_value(jsonb, uuid, jsonb) from public;
revoke all on function internal.rec_copy_from(text, uuid, date, public.date_precision) from public;
revoke all on function internal.rec_item(jsonb, jsonb) from public;
revoke all on function internal.rec_item_safe(jsonb, jsonb) from public;
revoke all on function internal.rec_open_set(uuid) from public;
revoke all on function internal.rec_cols(text, jsonb) from public;
