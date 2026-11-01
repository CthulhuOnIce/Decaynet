-- =============================================================================
-- Decaynet :: 0011 overlays become session-only; source-code link
--
-- Georeferenced scans and tile overlays are drawing aids in the workbench:
-- loaded from the editor's own computer for one session to trace footprints
-- and streets, then discarded. They are not stored or shown on the public map,
-- so the persistent overlay table and its permission go away.
--
-- AGPL-3.0 §13: users interacting with the app over a network must be offered
-- the corresponding source. site_settings.source_code_url powers that link.
-- =============================================================================

drop table if exists public.map_layers cascade;
delete from public.permissions where id = 'manage_layers';

alter table public.site_settings
  add column source_code_url text not null default 'https://github.com/CthulhuOnIce/Decaynet';
