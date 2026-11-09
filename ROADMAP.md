# Decaynet long-horizon tracker

A living plan for building the "Google Maps through history" of Gary, Indiana and the surrounding Calumet Region.
Update it in the same PR as the work. Check boxes when merged, and add a line to the log at the bottom when a
decision changes direction.

**Legend:** `[x]` done · `[~]` in progress / partial · `[ ]` not started · ⚑ needs a decision

---

## North star

Pick any address in Gary and any year since 1906, and see:

1. what stood there and what shape it was,
2. who occupied each part of it,
3. what it was called, what condition it was in, and what happened to it,
4. the photos, maps and documents that prove it, with every claim cited.

---

## Phase 0: Foundations ✅

- [x] Entity / component / system data model with temporal facts (fuzzy dates, precision, confidence, citations)
- [x] PostGIS geometries over time, ghosts of lost places
- [x] Time-machine map (year slider, play, histogram, shareable URLs)
- [x] Wiki articles with `[[links]]`, revisions, article status history
- [x] Change log (record time) + recent changes + per-page history
- [x] Tags with sub-traits (hierarchical, temporal, implied ancestors)
- [x] Media uploads with capture date, depicted period, camera viewpoint
- [x] Maintenance queues derived from data (unsourced, unmapped, orphan…)

## Phase 1: Platform & governance ✅

- [x] Roles × permissions matrix editable by admins (RLS enforced via `has_permission`)
- [x] Account page (profile, email, password), public contributor pages
- [x] First-admin bootstrap: ADMIN_EMAIL/ADMIN_PASSWORD, or a /setup wizard guarded by a setup code; first sign-up no longer auto-promoted once the server holds the service key
- [x] User admin: roles, suspension, last-admin protection
- [x] Site settings in the database (identity, map defaults, basemap, sign-ups, default role)
- [x] Server-only secrets store (captcha secret, IP salt)
- [x] Anonymous tips: optional images, IP mode (off / hash / full), captcha (Turnstile / hCaptcha), rate limit, honeypot
- [x] Tip review queue: status workflow, notes, link/create page, promote images to media
- [ ] Email notifications for new tips / watched pages ⚑ (Supabase SMTP vs. a queue + Resend)
- [x] Private pages: hidden from the public until published (RLS-enforced), default-private setting, import as private
- [ ] Private media files (signed URLs from a private bucket for media on private pages)
- [ ] Scheduled publishing and a review step ("ready for review" → moderator publishes)
- [ ] Watchlists ("tell me when this building's page changes")
- [ ] Talk / discussion threads per page and per fact
- [ ] Privacy notice + tip data retention job (auto-purge raw IPs after N days)
- [ ] Audit view for admins: permission changes, role changes, deletions

## Phase 2: Editor tooling for cross-referencing ✅ (first pass)

- [x] Workbench: session-only scan overlays (opened from disk, never uploaded) aligned by 4-corner pinning + move / rotate / scale
- [x] Alignment files (export / re-load corner positions as JSON) and session XYZ tile layers
- [x] Pin a sheet by typing a street corner (the wiki's dated streets, by any name; OpenStreetMap for the rest), with its scale bar and north arrow: one pin is enough
- [x] Sanborn books: align a volume's sheets one after another and export them together (world files, alignment files, index) for GIS
- [x] Blend, swipe and flicker (hold F) comparison of the scan vs. data
- [x] Trace footprints / streets over a scan with vertex snapping
- [x] End everything in an area at a date: select it with a box or lasso, untick what survived, mark it gone (cited)
- [x] GeoJSON import with per-feature date properties
- [ ] Control-point georeferencing (≥ 6 GCPs, polynomial / thin-plate warp) to replace 4-corner pinning ⚑ (client-side warp in WebGL)
- [ ] Faster handling of very large scans in the browser (tiling in a web worker)
- [ ] Split / merge / reshape existing geometries; "end this shape and start a new one" in one step
- [ ] Snap to overlay edges (edge detection) and to OSM building footprints
- [ ] Bulk occupancy import from city directories (CSV: year, name, address → occupancy relations via address matching)
- [ ] Shapefile / KML / CSV-with-WKT import (in-browser conversion)
- [ ] Export: GeoJSON / CSV per year or per area; full data dump for researchers
- [ ] Undo for bulk operations (change-log based revert)

## Phase 2b: External sources

- [x] Live import from OpenHistoricalMap (Overpass) and Wikidata (SPARQL) for a chosen area
- [x] Pairing OHM features with Wikidata items (wikidata tag, point-in-footprint, name + distance)
- [x] Matching against existing pages (external ids, Wikidata id, footprint overlap, compatible-kind name match)
- [x] Full preview with per-row actions; gap-filling merges that never overwrite; citations per import; undo
- [ ] Re-sync: re-preview previously imported areas and show what changed upstream
- [ ] OpenStreetMap (present-day) import for current footprints and addresses
- [ ] Wikidata: people and organizations connected to imported places (architects, occupants, owners) as linked pages
- [ ] Chronicling America / newspaper search links for imported places
- [ ] Write-back helpers: export new dated footprints in OHM-ready form for contributors who also map there

## Phase 3: Layout through time

The street grid, shoreline and river were not always where they are today. What exists so far, and what's next:

- [x] Temporal geometries on every entity (streets move, buildings grow)
- [x] Natural features as entities (`water`, `landform`): shoreline, Grand Calumet River, dunes, fill
- [x] Basemap modes: fade with time / always / hidden (for eras when today's streets are misleading)
- [x] Area retirement for clearances (Toll Road, urban renewal) → ghosts
- [x] `replaced` relation (old street → highway, old building → successor)
- [ ] **Layout epochs** ⚑: named, dated region-wide states (e.g. "1906 plat", "pre-Toll Road", "post-renewal") that bundle retired areas and traced geometry, so editors can switch whole eras
- [ ] Street segment model (intersections as nodes, segments as edges) so renumbering and partial vacations are exact
- [ ] Historical address renumbering tables (old number → new number by date) feeding the address resolver
- [ ] Parcel lineage (split / merge history) linked to buildings
- [ ] Historical basemap built from our own data (no modern tiles at all) via vector tiles (`ST_AsMVT`)
- [ ] Pre-1906 landscape: dunes, wetlands, Calumet River courses, Miller hamlet

## Phase 4: Inside buildings

- [x] Building footprints as true polygons
- [x] Spaces (storefronts, suites, halls, floors) as polygons inside footprints, validated to fit
- [x] Tenants occupy spaces over time; spaces render with tenant labels at high zoom
- [ ] Floor switcher on the map (show floor N) and multi-storey stacking
- [ ] Trace floor plans into spaces from scans (session overlay pinned inside the footprint)
- [ ] Residential units / apartment rosters from census and directories
- [ ] "Who was here" vertical timeline for a building (all spaces × all tenants, Gantt-style)

## Phase 5: Content & sources (the actual history)

- [ ] Verify and cite every seed fact; replace approximate seed coordinates with traced footprints
- [ ] Inventory Sanborn fire-insurance map holdings for Gary (Library of Congress, IU libraries, ProQuest): years, volumes, sheets
- [ ] Trace downtown footprints from each available Sanborn edition (session overlays in the workbench)
- [ ] Polk / city directories: transcribe Broadway and 5th Ave occupants by decade
- [ ] Calumet Regional Archives (IU Northwest): photo collections, oral histories, finding aids → sources
- [ ] Post-Tribune and Gary American indexes for demolitions, fires, openings, closings
- [ ] Trace from historical aerial series (USDA / USGS) in the workbench
- [ ] Neighborhood coverage: Downtown → Midtown → Emerson → Glen Park → Tolleston → Miller → Aetna → Brunswick
- [ ] Demolition and vacancy datasets from the city (where public)

## Phase 6: Reader experience

- [ ] Then / now photo compare (viewpoint + bearing → street-level juxtaposition)
- [ ] Camera viewpoint cones on the map
- [ ] Guided tours / story maps ("The rise and fall of Broadway")
- [ ] Per-building decay timeline chart (condition over time)
- [ ] Embeddable map widget for other sites
- [ ] Mobile layout pass, offline-friendly field mode for photographers
- [ ] Accessibility audit (keyboard map navigation, screen-reader summaries of map state)
- [ ] i18n scaffolding for the UI itself (content language is already a setting)
- [ ] Locale-aware date formatting (month names, day/month order)
- [ ] BCE / pre-1000 CE dates for global sites

## Phase 7: Scale & operations

- [ ] Vector tiles for snapshots (`ST_AsMVT` endpoint + caching) once GeoJSON gets heavy
- [ ] Materialized "year snapshots" refreshed on change for fast scrubbing
- [ ] Image thumbnails / derivatives (Supabase image transforms or a worker)
- [ ] Production tile provider; CDN caching for `/api/snapshot`
- [ ] Backups + point-in-time restore runbook
- [ ] CI: svelte-check, migration replay against PostGIS, Playwright smoke tests
- [ ] Generated Supabase types (`npm run db:types`) wired into server code
- [ ] Rate limiting on public API endpoints
- [x] Region-agnostic configuration (any city, country or the whole world)
- [x] Bundled self-hosted Supabase in docker compose
- [ ] Optional Supabase Studio / Mailpit services (profiles) in the bundled stack
- [ ] Federation between Decaynet sites (shared external ids, cross-site search) ⚑

---

## Open questions

- ⚑ **Georeferencing engine**: is 4-corner pinning good enough for Sanborn sheets (mostly orthogonal), or do we need GCP warping early? Proposal: 4-corner now, client-side GCP warp later. Scans stay session-only either way.
- ⚑ **Layout epochs**: explicit epoch table vs. emergent from dated geometries. Leaning towards a thin `epochs` table (name, date range, area polygon, overlays) used only for navigation and bulk tooling, while facts stay the source of truth.
- ⚑ **Raw IPs on tips**: default is salted hash. If an admin enables full IPs, add an automatic purge after 90 days?
- ⚑ **Moderation of anonymous media**: rights are unverified; require a reviewer to set a rights statement before publishing?

## Decision log

| Date | Decision |
|---|---|
| 2026-11-01 | Entities + temporal component tables + SQL systems (data-oriented model). |
| 2026-11-01 | Fuzzy dates expand to their precision window; latest-starting overlapping fact wins. |
| 2026-11-01 | Tags as a tree with temporal assignments; ancestors implied. |
| 2026-11-01 | Permissions are data (roles × permissions); `is_editor`/`is_moderator` reimplemented on `has_permission`. |
| 2026-11-01 | Tips are inserted only by the server (service role) so captcha, rate limits and IP policy can't be bypassed. |
| 2026-11-01 | Building → space → tenant; spaces must fit inside the footprint (2 m tolerance). |
| 2026-11-01 | Dropped shadcn-svelte adoption; keep the hand-rolled design system. |
| 2026-11-01 | Overlays (scans, tile layers) are session-only drawing aids in the workbench, not stored or published. `map_layers` dropped. |
| 2026-11-01 | Licensed AGPL-3.0-or-later; ship as a Docker image. |
| 2026-11-01 | External data (OHM, Wikidata) is fetched live in the app and always previewed; imports fill gaps, never overwrite, and can be undone. No bundled data dumps. |
| 2026-11-01 | Region-agnostic: no city in code or schema; Gary is an optional demo seed. Region, units, address format, language, bounds and vocabulary are site settings. |
| 2026-11-01 | Private pages are enforced in the database (RLS on entities and every per-entity table), not in the UI; personalised API responses are never publicly cacheable. |
| 2026-11-01 | Compose stack is Portainer-ready: no bind mounts or build steps; images published to GHCR by CI; health checks probe 127.0.0.1 with start periods. |
| 2026-11-01 | `docker compose up` bundles a self-hosted Supabase (db, auth, rest, storage, kong); an external-Supabase compose file remains for Supabase Cloud. |
