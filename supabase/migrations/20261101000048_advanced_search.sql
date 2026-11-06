-- =============================================================================
-- Decaynet :: 0048 advanced search (and searching the map's years)
--
-- advanced_search(p) takes every filter as one JSON object, all optional:
--   q            text to look for; match: fuzzy (default; close spellings and
--                parts of words) | contains | starts | exact
--   in           where to look: names (title and every other name), addresses,
--                summary, article (default: names)
--   kinds        page kinds
--   from_year,   only what existed at some point in these years: the time
--   to_year      machine is the map's year and the five before. Names and
--                addresses are matched as they were then, and each result
--                carries its name and condition then
--   started / ended   {from, to}: the lifespan's start or end within years
--   statuses, status_none, status_year   the condition in a year (to_year by
--                default), or no condition recorded then
--   tags (ids, with sub-traits), tags_any / tags_none
--   article_statuses, confidences (of the lifespan)
--   props        {start, end, shape, address, condition, sources, article,
--                photos, tags, links, names}: 'set' or 'unset'
--   facts        [{key, min, max, text, unset}] a fact in a range, matching
--                text, or not recorded
--   street, number_from, number_to   an address on a street (any of its
--                names) within house numbers
--   sort         relevance | name | start | end | updated; limit, offset
-- Each row carries the total matched (for paging) and a point to fly the map to.
-- =============================================================================

/** Does a text match the query, the way the search asked? */
create or replace function public.search_text_matches(t text, q text, mode text) returns boolean
language sql immutable parallel safe set search_path = public, extensions as $$
  select t is not null and case mode
    when 'exact' then lower(btrim(t)) = lower(q)
    when 'starts' then t ilike replace(replace(q, '%', '\%'), '_', '\_') || '%'
    when 'contains' then t ilike '%' || replace(replace(q, '%', '\%'), '_', '\_') || '%'
    -- fuzzy: contains, a close spelling of the whole, or of a word in it ("Hotl Gary", "Kresges")
    else t ilike '%' || replace(replace(q, '%', '\%'), '_', '\_') || '%' or similarity(t, q) >= 0.35 or word_similarity(q, t) >= 0.6
  end
$$;

create or replace function public.search_text_score(t text, q text) returns real
language sql immutable parallel safe set search_path = public, extensions as $$
  select (greatest(similarity(t, q), word_similarity(q, t) * 0.9)
          + case when lower(btrim(t)) = lower(q) then 2 when t ilike q || '%' then 1 when t ilike '%' || q || '%' then 0.5 else 0 end)::real
$$;

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
  v_lim int := least(greatest(coalesce(nullif(p ->> 'limit', '')::int, 50), 1), 200);
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
    'names', 'exists (select 1 from public.entity_names x where x.entity_id = e.id)');
begin
  if y0 is not null or y1 is not null then
    v_win := daterange(case when y0 is not null then make_date(y0, 1, 1) end, case when y1 is not null then make_date(y1 + 1, 1, 1) end, '[)');
    v_wsql := format('%L::daterange', v_win);
  end if;

  -- ------------------------------------------------------------------ which pages
  arr := (select array_agg(x) from jsonb_array_elements_text(p -> 'kinds') x);
  if arr is not null then w := w || format('e.kind = any (%L::text[])', arr); end if;
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

grant execute on function public.search_text_matches(text, text, text) to anon, authenticated;
grant execute on function public.search_text_score(text, text) to anon, authenticated;
grant execute on function public.advanced_search(jsonb) to anon, authenticated;
