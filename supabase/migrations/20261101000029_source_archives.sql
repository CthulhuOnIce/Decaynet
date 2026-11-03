-- =============================================================================
-- Decaynet :: 0029 archived copies of source links
--
-- Links rot. The app now saves each source's link to the Internet Archive in the
-- background (reusing a recent snapshot when there is one) and keeps the
-- snapshot in sources.archive_url, so nobody has to paste it by hand.
--
--   sources.archive_auto        the archive link was filled in by the app
--   sources.archive_checked_at  last attempt (the background sweep retries daily)
--   sources.archive_error       why the last attempt didn't work, for editors
--   site_settings.archive_sources   on by default; off stops sending links out
--
-- An archive link typed in by hand is never replaced. An automatic one is
-- cleared (and redone) when the source's link changes.
-- =============================================================================

alter table public.sources
  add column if not exists archive_auto boolean not null default false,
  add column if not exists archive_checked_at timestamptz,
  add column if not exists archive_error text;

alter table public.site_settings
  add column if not exists archive_sources boolean not null default true;

comment on column public.sources.archive_auto is 'archive_url was saved automatically (Internet Archive), not typed in.';
comment on column public.site_settings.archive_sources is 'Save source links to the Internet Archive automatically.';

create or replace function internal.source_link_changed() returns trigger
language plpgsql as $$
begin
  if new.url is distinct from old.url then
    -- an automatic snapshot belonged to the old link; a hand-entered one is left alone
    if old.archive_auto and new.archive_url is not distinct from old.archive_url then
      new.archive_url := null;
      new.archive_auto := false;
    end if;
    new.archive_checked_at := null;
    new.archive_error := null;
  end if;
  return new;
end;
$$;

drop trigger if exists source_link_changed on public.sources;
create trigger source_link_changed before update of url on public.sources
  for each row execute function internal.source_link_changed();

-- the sweep looks for these
create index if not exists sources_to_archive_idx on public.sources (archive_checked_at nulls first)
  where url is not null and archive_url is null;
