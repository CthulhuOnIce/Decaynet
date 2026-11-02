-- =============================================================================
-- Decaynet :: 0018 page sources
--
-- A source no longer has to be registered in the shared library before it can
-- be cited. Contributors can create one right where they need it, while adding
-- a fact or writing an article. Such a source belongs to that page:
--   * sources.entity_id = the page it was made for (null = shared library)
--   * the page's fact forms and article editor offer it; other pages and the
--     /sources library don't, so one-off clippings don't clutter the list
--   * "Add to library" clears entity_id to share it with every page
--   * it follows its page: hidden while the page is private, deleted with it
-- =============================================================================

alter table public.sources
  add column entity_id uuid references public.entities (id) on delete cascade;

comment on column public.sources.entity_id is
  'Page this source was created for (cited by its facts or article). Null = shared library source.';

create index sources_entity_idx on public.sources (entity_id) where entity_id is not null;

-- Page sources are only as visible as their page
drop policy if exists "read sources" on public.sources;
create policy "read visible sources" on public.sources for select to anon, authenticated
  using (entity_id is null
         or (select public.has_permission('view_private'))
         or not public.entity_hidden(entity_id));
