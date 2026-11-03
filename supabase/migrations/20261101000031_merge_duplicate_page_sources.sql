-- =============================================================================
-- Decaynet :: 0031 merge duplicate page sources
--
-- Forms that keep their fields after saving (the workbench, editing a fact) made
-- a fresh copy of a "New source…" every time they were saved again, so one
-- source could appear several times on a page. The app now reuses an identical
-- source instead; this merges the copies already made.
--
-- Copies = sources made for the same page with the same title, link, kind,
-- author, publisher, date, repository, call number and notes. The oldest is
-- kept; every fact, media item and article citation pointing at a copy is
-- pointed at it, it takes over an archived link if only a copy had one, and the
-- copies are deleted. Library sources are left alone.
-- =============================================================================

do $$
declare
  fk record;
  r record;
  n int;
begin
  create temp table _dup_sources (dup uuid primary key, keep uuid not null);

  insert into _dup_sources (dup, keep)
  select id, keep
    from (select id,
                 first_value(id) over (
                   partition by entity_id, lower(btrim(title)), coalesce(btrim(url), ''), kind,
                                lower(coalesce(btrim(author), '')), lower(coalesce(btrim(publisher), '')),
                                published_on, published_precision,
                                coalesce(btrim(repository), ''), coalesce(btrim(call_number), ''),
                                coalesce(btrim(notes), '')
                   order by created_at, id) as keep
            from public.sources
           where entity_id is not null) s
   where id <> keep;

  get diagnostics n = row_count;
  raise notice 'merging % duplicate page source(s)', n;

  if n > 0 then
    -- every table that cites a source
    for fk in
      select c.conrelid::regclass as tbl, a.attname as col
        from pg_constraint c
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
       where c.confrelid = 'public.sources'::regclass and c.contype = 'f'
    loop
      execute format('update %s t set %I = d.keep from _dup_sources d where t.%I = d.dup', fk.tbl, fk.col, fk.col);
    end loop;

    -- [cite:<id>] in articles (and their saved revisions, so restoring one keeps working)
    for r in select dup, keep from _dup_sources loop
      update public.articles
         set body = regexp_replace(body, '\[cite:' || r.dup::text, '[cite:' || r.keep::text, 'gi')
       where body ilike '%[cite:' || r.dup::text || '%';
      update public.article_revisions
         set body = regexp_replace(body, '\[cite:' || r.dup::text, '[cite:' || r.keep::text, 'gi')
       where body ilike '%[cite:' || r.dup::text || '%';
    end loop;

    -- keep an archived copy if only a duplicate had one
    update public.sources k
       set archive_url = d.archive_url, archive_auto = d.archive_auto,
           archive_checked_at = d.archive_checked_at, archive_error = null
      from (select distinct on (keep) keep, s.archive_url, s.archive_auto, s.archive_checked_at
              from _dup_sources join public.sources s on s.id = dup
             where s.archive_url is not null
             order by keep, s.archive_checked_at desc nulls last) d
     where k.id = d.keep and k.archive_url is null;

    delete from public.sources where id in (select dup from _dup_sources);
  end if;

  drop table _dup_sources;
end;
$$;
