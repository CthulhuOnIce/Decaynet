-- =============================================================================
-- Decaynet :: 0034 timeline style
--
-- How a page's timeline is drawn (on the page and in its printable export):
--   table    a table: dates and descriptions wrap in their own columns (default)
--   bubbles  a dot per entry with its date, the details in a bubble below it
-- =============================================================================

alter table public.site_settings
  add column if not exists timeline_style text not null default 'table'
  check (timeline_style in ('table', 'bubbles'));

comment on column public.site_settings.timeline_style is 'How page timelines are drawn: table or bubbles.';
