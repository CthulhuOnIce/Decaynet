-- =============================================================================
-- Decaynet :: 0030 archive page sources too
--
-- 0029 held back sources made for a private page until it was published. Their
-- links are other sites' public pages, so page sources (fact and article
-- citations) are now archived like library sources. Release the ones that were
-- waiting so the next sweep (or save) archives them.
-- =============================================================================

update public.sources
   set archive_checked_at = null, archive_error = null
 where archive_url is null
   and archive_error = 'Waiting until the page is published.';
