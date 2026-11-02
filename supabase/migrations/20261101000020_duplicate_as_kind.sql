-- =============================================================================
-- Decaynet :: 0020 duplicate a page as another kind
--
-- Imports and quick edits often get the kind wrong: a "building" that is
-- really the business inside it, a site that is a building, an event page
-- created as a place. Rather than changing the page in place (and losing
-- whatever doesn't fit the new kind), this makes a NEW page of the right kind
-- next to the original and copies everything that fits. The original is left
-- exactly as it was; a person reviews the copy and then deletes or keeps the
-- original.
--
-- What the copy gets:
--   always       name, summary, lifespan, privacy, other names, tags, the
--                article (as a new revision), facts that apply to the new kind,
--                links whose kinds fit, and the original's own page sources
--                (citations in the copied facts and article point at the copies)
--   place facts  footprint/shapes, addresses, conditions and place links
--   (tenants, spaces, "is on", architect…) are copied too, except when a
--                place becomes an occupant (building → organization, person or
--                event): they stay with the original place, and the new page is
--                linked to it instead (occupies / lived at / happened at), over
--                the page's lifespan. An occupant becoming a place (organization
--                → building) is linked the other way.
--   never        external ids (one page per OpenHistoricalMap way / Wikidata
--                item, so they stay with the original), media files
--                (media pages can't be duplicated as another kind)
--
--   duplicate_as_kind_preview(page, kind)   what would be copied / left
--   duplicate_as_kind(page, kind, name)     make the copy; returns its slug
-- Needs "Edit content" and a page the caller can see.
-- =============================================================================

create or replace function internal.ck_is_place(k text) returns boolean language sql immutable as $$
  select k in ('building', 'site', 'parcel', 'space', 'street', 'infrastructure', 'district', 'water', 'landform')
$$;
-- the link from an occupant of this kind to its place
create or replace function internal.ck_link(p_kind text) returns text language sql immutable as $$
  select case p_kind when 'organization' then 'occupies' when 'person' then 'resides_at' when 'event' then 'occurred_at' end
$$;
-- links that belong to a place: it is the object of these …
create or replace function internal.ck_place_in() returns text[] language sql immutable as $$
  select array['occupies', 'resides_at', 'owns', 'part_of']
$$;
-- … or the subject of these
create or replace function internal.ck_place_out() returns text[] language sql immutable as $$
  select array['located_on', 'located_in', 'part_of', 'intersects', 'designed_by', 'built_by']
$$;
revoke all on function internal.ck_is_place(text) from public;
revoke all on function internal.ck_link(text) from public;
revoke all on function internal.ck_place_in() from public;
revoke all on function internal.ck_place_out() from public;

/*
 * The plan both functions share: every fact of the page, with whether it is
 * copied and why not. Rows: {what, table, id, label, copy, why}
 *   why: place (stays with the original place), kind (doesn't fit the new
 *        kind), unique (external id)
 */
create or replace function internal.ck_plan(p_entity uuid, p_kind text)
returns table (what text, tbl text, row_id uuid, label text, copy boolean, why text)
language sql stable set search_path = public, extensions as $$
  with e as (
    select x.*, internal.ck_is_place(x.kind) and not internal.ck_is_place(p_kind) as to_occupant
      from public.entities x where x.id = p_entity
  )
  select 'name', 'entity_names', n.id, n.name, true, null from public.entity_names n where n.entity_id = p_entity
  union all
  select 'tag', 'entity_tags', t.id, tg.label, true, null
    from public.entity_tags t join public.tags tg on tg.id = t.tag_id where t.entity_id = p_entity
  union all
  select 'fact', 'entity_attributes', a.id, coalesce(k.label, a.key) || ': ' || (a.value #>> '{}'),
         k.applies_to is null or p_kind = any (k.applies_to),
         case when not (k.applies_to is null or p_kind = any (k.applies_to)) then 'kind' end
    from public.entity_attributes a left join public.attribute_keys k on k.id = a.key where a.entity_id = p_entity
  union all
  select 'shape', 'entity_geometries', g.id, g.role, not e.to_occupant, case when e.to_occupant then 'place' end
    from public.entity_geometries g, e where g.entity_id = p_entity and g.role <> 'viewpoint'
  union all
  select 'address', 'addresses', a.id,
         coalesce(case when s.id is not null then nullif(trim(concat_ws(' ', a.house_number, s.name, a.unit)), '') end,
                  a.raw_address, a.house_number, 'address'),
         not e.to_occupant, case when e.to_occupant then 'place' end
    from public.addresses a left join public.entities s on s.id = a.street_id, e where a.entity_id = p_entity
  union all
  select 'condition', 'entity_states', st.id, ls.label, not e.to_occupant, case when e.to_occupant then 'place' end
    from public.entity_states st join public.lifecycle_statuses ls on ls.id = st.status, e where st.entity_id = p_entity
  union all
  select 'link', 'relations', r.id,
         case when r.subject_id = p_entity then rt.label else rt.inverse_label end || ' ' || o.name,
         not place_link and fits, case when place_link then 'place' when not fits then 'kind' end
    from public.relations r
    join public.relation_types rt on rt.id = r.predicate
    join public.entities o on o.id = case when r.subject_id = p_entity then r.object_id else r.subject_id end
    cross join e
    cross join lateral (select
      e.to_occupant and ((r.object_id = p_entity and r.predicate = any (internal.ck_place_in()))
                      or (r.subject_id = p_entity and r.predicate = any (internal.ck_place_out()))) as place_link,
      case when r.subject_id = p_entity then rt.subject_kinds is null or p_kind = any (rt.subject_kinds)
           else rt.object_kinds is null or p_kind = any (rt.object_kinds) end as fits) f
   where r.subject_id = p_entity or r.object_id = p_entity
  union all
  select 'map id', 'entity_external_ids', null, upper(x.source) || ' ' || x.external_id, false, 'unique'
    from public.entity_external_ids x where x.entity_id = p_entity
$$;
revoke all on function internal.ck_plan(uuid, text) from public;

-- Which link ties the copy to the original (null: none)
create or replace function internal.ck_tie(p_from text, p_to text)
returns table (predicate text, copy_is_subject boolean)
language sql immutable as $$
  -- a place becoming an occupant: the copy occupies / lived at / happened at the original
  select internal.ck_link(p_to), true
   where internal.ck_is_place(p_from) and not internal.ck_is_place(p_to) and internal.ck_link(p_to) is not null
     and (p_to = 'event' or p_from in ('building', 'site', 'parcel', 'space'))
  union all
  -- an occupant becoming a place: the original occupies / lived at / happened at the copy
  select internal.ck_link(p_from), false
   where internal.ck_is_place(p_to) and not internal.ck_is_place(p_from) and internal.ck_link(p_from) is not null
     and (p_from = 'event' or p_to in ('building', 'site', 'parcel', 'space'))
$$;
revoke all on function internal.ck_tie(text, text) from public;

-- -----------------------------------------------------------------------------
-- Preview
-- -----------------------------------------------------------------------------
create or replace function public.duplicate_as_kind_preview(p_entity uuid, p_kind text)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  e record;
  v_tie record;
begin
  if public.entity_hidden(p_entity) then
    return null;
  end if;
  select x.id, x.kind, x.name, k.label into e
    from public.entities x join public.entity_kinds k on k.id = x.kind where x.id = p_entity;
  if not found then
    return null;
  end if;
  if not exists (select 1 from public.entity_kinds where id = p_kind) then
    return jsonb_build_object('blocked', 'Unknown kind.');
  end if;
  if p_kind = e.kind then
    return jsonb_build_object('blocked', 'It already is one.');
  end if;
  if 'media' in (p_kind, e.kind) then
    return jsonb_build_object('blocked', 'Media pages hold a file, so they can''t be duplicated as another kind. Create a new page instead.');
  end if;
  select * into v_tie from internal.ck_tie(e.kind, p_kind);

  return jsonb_build_object(
    'from', e.kind, 'from_label', e.label,
    'to', p_kind, 'to_label', (select label from public.entity_kinds where id = p_kind),
    'name', e.name,
    'article', coalesce((select length(body) > 0 from public.articles where entity_id = p_entity), false),
    'sources', (select count(*) from public.sources where entity_id = p_entity),
    'tie', case when v_tie.predicate is not null then jsonb_build_object(
             'reading', (select label from public.relation_types where id = v_tie.predicate),
             'copy_is_subject', v_tie.copy_is_subject) end,
    'event', p_kind = 'event',
    'copied', (select coalesce(jsonb_agg(jsonb_build_object('what', what, 'label', label) order by what, label), '[]'::jsonb)
                 from internal.ck_plan(p_entity, p_kind) where copy),
    'left', (select coalesce(jsonb_agg(jsonb_build_object('what', what, 'label', label, 'why', why) order by why, what, label), '[]'::jsonb)
               from internal.ck_plan(p_entity, p_kind) where not copy));
end;
$$;

-- -----------------------------------------------------------------------------
-- Duplicate
-- -----------------------------------------------------------------------------
create or replace function public.duplicate_as_kind(p_entity uuid, p_kind text, p_name text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  e record;
  v_new uuid;
  v_slug text;
  v_name text;
  v_map jsonb := '{}'::jsonb;   -- original page source id -> copy
  s record;
  v_sid uuid;
  t text;
  v_cols text;
  v_body text;
  v_tie record;
  v_copied int := 0;
  n int;
begin
  if not public.has_permission('edit_content') then
    raise exception 'You need the edit content permission' using errcode = '42501';
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or public.entity_hidden(p_entity) then
    raise exception 'Page not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.entity_kinds where id = p_kind) then
    raise exception 'Unknown kind “%”', p_kind using errcode = '22023';
  end if;
  if p_kind = e.kind then
    raise exception 'It already is one' using errcode = '22023';
  end if;
  if 'media' in (p_kind, e.kind) then
    raise exception 'Media pages can''t be duplicated as another kind' using errcode = '22023';
  end if;

  -- the new page
  v_name := coalesce(nullif(trim(p_name), ''), e.name);
  v_slug := left(coalesce(nullif(trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g')), ''), p_kind), 70);
  if exists (select 1 from public.entities where slug = v_slug) then
    v_slug := left(v_slug, 60) || '-' || p_kind;
  end if;
  if exists (select 1 from public.entities where slug = v_slug) then
    v_slug := v_slug || '-' || substr(md5(random()::text), 1, 5);
  end if;
  insert into public.entities (kind, slug, name, summary, exists_from, exists_from_precision, exists_to, exists_to_precision,
                               lifespan_confidence, is_private, created_by)
  values (p_kind, v_slug, v_name, e.summary, e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision,
          e.lifespan_confidence, e.is_private, auth.uid())
  returning id into v_new;
  if p_kind = 'event' then
    insert into public.event_details (entity_id, event_type)
    values (v_new, coalesce((select event_type from public.event_details where entity_id = p_entity),
                            (select id from public.event_types where id = 'other'),
                            (select id from public.event_types order by sort limit 1)));
  end if;

  -- the original's own sources, so deleting it later can't take the citations along
  for s in select * from public.sources where entity_id = p_entity loop
    insert into public.sources (title, kind, author, publisher, published_on, published_precision, url, archive_url,
                                repository, call_number, notes, entity_id, created_by)
    values (s.title, s.kind, s.author, s.publisher, s.published_on, s.published_precision, s.url, s.archive_url,
            s.repository, s.call_number, s.notes, v_new, auth.uid())
    returning id into v_sid;
    v_map := v_map || jsonb_build_object(s.id::text, v_sid);
  end loop;

  -- facts kept on the page itself
  foreach t in array array['entity_names', 'entity_tags', 'entity_attributes', 'entity_geometries', 'addresses', 'entity_states'] loop
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into v_cols
      from information_schema.columns
     where table_schema = 'public' and table_name = t and is_generated = 'NEVER'
       and column_name not in ('id', 'entity_id', 'source_id', 'created_by', 'created_at', 'updated_at');
    execute format(
      'insert into public.%1$I (entity_id, source_id, created_by, %2$s)
       select $1, coalesce(($3 ->> x.source_id::text)::uuid, x.source_id), auth.uid(), %3$s
         from public.%1$I x
        where x.id in (select row_id from internal.ck_plan($2, $4) where copy and tbl = %4$L)',
      t, v_cols, (select string_agg('x.' || c, ', ') from unnest(string_to_array(v_cols, ', ')) c), t)
      using v_new, p_entity, v_map, p_kind;
    get diagnostics n = row_count;
    v_copied := v_copied + n;
  end loop;

  -- links, from the copy's side
  insert into public.relations (subject_id, predicate, object_id, qualifiers, valid_from, valid_from_precision, valid_to,
                                valid_to_precision, confidence, source_id, source_detail, note, created_by)
  select case when r.subject_id = p_entity then v_new else r.subject_id end, r.predicate,
         case when r.object_id = p_entity then v_new else r.object_id end, r.qualifiers,
         r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision, r.confidence,
         coalesce((v_map ->> r.source_id::text)::uuid, r.source_id), r.source_detail, r.note, auth.uid()
    from public.relations r
   where r.id in (select row_id from internal.ck_plan(p_entity, p_kind) where copy and tbl = 'relations');
  get diagnostics n = row_count;
  v_copied := v_copied + n;

  -- tie the copy to the original (occupant ↔ place), over the lifespan
  select * into v_tie from internal.ck_tie(e.kind, p_kind);
  if v_tie.predicate is not null then
    insert into public.relations (subject_id, predicate, object_id, valid_from, valid_from_precision, valid_to, valid_to_precision,
                                  confidence, note, created_by)
    values (case when v_tie.copy_is_subject then v_new else p_entity end, v_tie.predicate,
            case when v_tie.copy_is_subject then p_entity else v_new end,
            e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision, 'approximate',
            'Added when “' || e.name || '” was duplicated as a ' || p_kind || '.', auth.uid());
  end if;

  -- the article, as a revision of the new page (citations follow the copied sources)
  select body into v_body from public.articles where entity_id = p_entity;
  if coalesce(v_body, '') <> '' then
    for s in select key, value from jsonb_each_text(v_map) loop
      v_body := replace(v_body, '[cite:' || s.key, '[cite:' || s.value);
    end loop;
    perform public.save_article(v_new, v_body, 'Copied from “' || e.name || '” (' || e.kind || ')');
  end if;

  return jsonb_build_object('id', v_new, 'slug', v_slug, 'copied', v_copied, 'sources', jsonb_array_length(jsonb_path_query_array(v_map, '$.*')));
end;
$$;

revoke execute on function public.duplicate_as_kind_preview(uuid, text) from public, anon;
revoke execute on function public.duplicate_as_kind(uuid, text, text) from public, anon;
grant execute on function public.duplicate_as_kind_preview(uuid, text) to authenticated;
grant execute on function public.duplicate_as_kind(uuid, text, text) to authenticated;
