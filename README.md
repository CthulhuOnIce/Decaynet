# Decaynet

**A time-machine map and community wiki for Gary, Indiana and the Calumet Region.**
Drag a slider from 1890 to today and watch streets get laid out, buildings rise, change hands, empty out, burn and disappear. Every place, person, business, photo and event is a wiki page, and every fact on it has a date, a confidence level and a source.

![The time-machine map in 1955, with City Methodist Church selected](docs/images/map-1955.png)

Built with **SvelteKit 2 / Svelte 5**, **Supabase** (Postgres 17 + PostGIS, Auth, Storage) and **MapLibre GL**. Licensed **AGPL-3.0-or-later**.

---

## Contents

- [What it does](#what-it-does)
- [Quick start with Docker](#quick-start-with-docker)
- [Local development](#local-development)
- [Guides](#guides)
  - [Reading the map](#reading-the-map)
  - [Adding and editing pages](#adding-and-editing-pages)
  - [Buildings, spaces and tenants](#buildings-spaces-and-tenants)
  - [Tracing from a scanned map (workbench)](#tracing-from-a-scanned-map-workbench)
  - [When a whole area's layout changed](#when-a-whole-areas-layout-changed)
  - [Importing GIS data](#importing-gis-data)
  - [Starter pages from OpenHistoricalMap & Wikidata](#starter-pages-from-openhistoricalmap--wikidata)
  - [Anonymous tips](#anonymous-tips)
  - [Administration](#administration)
  - [Keeping quality up](#keeping-quality-up)
- [How the data model works](#how-the-data-model-works)
- [Configuration reference](#configuration-reference)
- [Project layout](#project-layout)
- [About the demo data](#about-the-demo-data)
- [Roadmap & contributing](#roadmap--contributing)
- [License](#license)

---

## What it does

| | |
|---|---|
| ![1995: the same blocks after decline](docs/images/map-1995.png) | **Time machine.** Everything on the map is folded to the year on the slider: names, shapes, condition (active → vacant → abandoned → ruin → demolished), occupants and nearby events. The modern basemap fades as you go back. |
| ![A building page](docs/images/entity-page.png) | **A wiki page for everything**, with prose, a dated timeline of every fact, connections, tags, spaces and tenants, photos, footnoted sources and a "snapshot as of year X" box. |
| ![Tenants inside buildings](docs/images/map-spaces.png) | **Real building footprints** with **spaces inside them** (storefronts, suites, halls). Tenants occupy spaces over time, and at high zoom the map labels each space with who was there that year. |
| ![The workbench](docs/images/workbench-trace.png) | **Editor workbench.** Pin a scanned Sanborn sheet over the map for the session, compare it with the data, and trace footprints and streets from it. Also bulk tools for area changes and GeoJSON import. |
| ![Import preview](docs/images/import-preview.png) | **Live import from OpenHistoricalMap and Wikidata.** Pick an area, fetch, and review a preview of every page that would be created or filled in before anything is written. |
| ![The tip form](docs/images/tip-form.png) | **Anonymous tips.** Guests can send what they know, with optional photos and a map pin. Optional captcha, IP policy and rate limiting; editors review tips in a queue. |

Also included:
- tags with sub-traits (*Business type › Food & drink › Restaurant › Soul food*)
- article status tracked over time
- recent changes and full history
- a roles × permissions matrix
- site settings editable in the browser
- maintenance queues computed from the data

---

## Quick start with Docker

Decaynet is one container (the SvelteKit app) plus a Supabase project. Supabase provides Postgres + PostGIS, Auth and Storage. You can use **Supabase Cloud**, **self-hosted Supabase**, or the **Supabase CLI** on your machine.

### 1. Get a Supabase project

<details open>
<summary><b>Option A: Supabase Cloud</b></summary>

1. Create a project at [supabase.com](https://supabase.com).
2. From **Project Settings → API**, copy the project URL, the `anon` key and the `service_role` key.
3. From **Project Settings → Database**, copy the connection string (use the *session* pooler or direct connection).
4. In **Authentication → URL Configuration**, add `https://YOUR-SITE/auth/callback` to the redirect URLs.

</details>

<details>
<summary><b>Option B: Supabase on your machine (CLI)</b></summary>

```bash
npm install            # installs the Supabase CLI locally
npx supabase start     # Postgres+PostGIS, Auth, Storage in Docker; applies migrations + demo data
npx supabase status    # prints the URL and keys
```

Use `http://host.docker.internal:54321` as `SUPABASE_INTERNAL_URL` so the container can reach it, and
`postgresql://postgres:postgres@host.docker.internal:54322/postgres` as `DATABASE_URL`.

</details>

### 2. Configure

```bash
cp .env.example .env
```

Fill in `PUBLIC_SUPABASE_URL`, `PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `ORIGIN` (the public URL of your site) and `DATABASE_URL`. See the [configuration reference](#configuration-reference).

### 3. Create the schema, then start the app

```bash
# Apply database migrations (SEED=1 also loads the Gary demo data into an empty database)
SEED=1 docker compose --profile tools run --rm migrate

# Build and start the app on http://localhost:3000
docker compose up -d app
```

The migration runner is idempotent and records versions in the same table the Supabase CLI uses, so `supabase db push` and the container can be mixed. It only works against a **Supabase** database, because it needs the `auth` and `storage` schemas.

### 4. Create the first account

Open the site and choose **Sign in → Create account**. **The first account becomes admin.** Then open **Admin → Site settings** to name the site, centre the map and configure tips.

### Production notes

- **Reverse proxy / HTTPS:** set `ORIGIN=https://your-domain`. To give tips the visitor's real IP, set `ADDRESS_HEADER=X-Forwarded-For` and `XFF_DEPTH=1` (commented out in `docker-compose.yml`).
- **Uploads:** the image sets `BODY_SIZE_LIMIT=25M` so tips with photos and GeoJSON imports fit. Raise it if you import large files.
- **Health check:** `GET /healthz` reports app and database status, and the image's `HEALTHCHECK` uses it.
- **Basemap:** the default modern basemap is the public OpenStreetMap tile server, which is fine for light use. For real traffic, set your own tile URL in Site settings, per the [OSM tile policy](https://operations.osmfoundation.org/policies/tiles/).
- **Docker Hub rate limits:** build from a mirror with `--build-arg NODE_IMAGE=public.ecr.aws/docker/library/node:22-alpine --build-arg PG_IMAGE=public.ecr.aws/docker/library/postgres:17-alpine`.
- **TLS-intercepting proxy** (corporate networks): pass its CA to the build with `docker build --secret id=ca,src=/path/to/ca.pem .`

---

## Local development

Requires Node 20+ and Docker (for the local Supabase stack).

```bash
npm install
npx supabase start          # database, auth, storage + migrations + demo data
cp .env.example .env        # paste URL, anon key and service-role key from `npx supabase status`
npm run dev                 # http://localhost:5173
```

| Command | |
|---|---|
| `npm run dev` | Dev server with hot reload |
| `npm run check` | Type-check (svelte-check) |
| `npm run build && node build` | Production build (adapter-node) |
| `npm run db:reset` | Rebuild the local database from `supabase/migrations` + `supabase/seed.sql` |
| `npm run db:types` | Generate TypeScript types from the database |

---

## Guides

### Reading the map

![Filtering the map by tag: every entertainment venue standing in 1955](docs/images/map-tag-filter.png)

- **Year slider:** drag it, use ←/→ (Shift for a decade), or press ▶ to play history forward. The amber ticks above the slider show when things happened.
- **Click anything** to see it *as of that year*: its name then, its condition, address, tenants, connections and photos. Links in the panel jump to other pages at the same year.
- **Colours** show condition: green for active, amber for declining or vacant, rust for abandoned, dark red for ruin. *Ghosts* (dashed outlines) are places already gone by the chosen year.
- **Layers panel:**
  - toggle kinds (streets, buildings, spaces, water…);
  - choose how the modern basemap behaves (*fade with time*, *always*, *hidden*);
  - filter to things carrying a tag, including its sub-traits.
- **Events ±5 years** appear as glowing dots and in a list. Things fade with distance in time.
- **Share a view:** the URL keeps the year, selection, map position and tag filter, for example `/?y=1955&sel=…&c=-87.338,41.601,15.4&tag=entertainment`.
- **Search** matches historic names too: "Genesis Towers" finds Hotel Gary.

### Adding and editing pages

![The structured facts editor](docs/images/facts-editor.png)

1. **Create a page** with **+ New**. Pick its kind (building, street, business, person, event…), a name, and when it began and ended. Optionally drop a point on the map.
2. **Add facts** on the page's **Edit facts** screen. Every fact has its own time window:

   | Section | Examples |
   |---|---|
   | Names over time | "Hotel Gary" 1927–1970s, then "Genesis Towers" |
   | Condition over time | Active 1926–1975 → Abandoned → Ruin (1990s) |
   | Addresses | 577 + *Washington Street* (linked to the street page, so it follows renamings) |
   | Attributes | Architectural style, floors, construction cost, population… |
   | Relations | *occupied by*, *owned by*, *designed by*, *happened at*, *depicts*… with qualifiers like `office=Mayor` |
   | Tags | *Business type › Entertainment › Movie theater*, dated if the use changed |
   | Location & shape | Footprints, centerlines, boundaries; a new shape when it moved or grew |

3. **Dates can be fuzzy.** Type them the way historians write them:

   | You type | Stored as |
   |---|---|
   | `1926` | the year 1926 |
   | `1920s` | the decade, so it counts for all of 1920–1929 |
   | `c. 1926`, `1926?` | 1926, marked *approximate* |
   | `May 1926`, `1926-05` | the month |
   | `May 12, 1926`, `1926-05-12` | the day |

   Leave **Until** blank if something is still true.
4. **Cite it.** Add the source once on the **Sources** page, then choose it on any fact, with a page or frame number. Mark uncertain facts *approximate*, *speculative* or *disputed*.
5. **Write the article** with **Edit article** (Markdown). Link pages with `[[slug]]` or `[[slug|label]]`; links to pages that don't exist yet show red. Set the article status (stub → draft → needs sources → needs review → good) and add an edit summary.
6. **Add media** with **+ Media**. A photo has three dates: when it was taken, the period it shows, and when it was added. You can also mark where the camera stood.

### Buildings, spaces and tenants

![Dividing a footprint into spaces](docs/images/facts-spaces.png)

Buildings are polygons, not dots. To record who occupied which part:

1. Give the building a **footprint**: trace it in the workbench, or draw it under **Edit facts → Location & shape**.
2. Under **Edit facts → Spaces**, draw each storefront, suite or hall *inside* the footprint. Corners snap to the footprint, and a space that pokes out more than 2 m is rejected.
3. Click **+ Tenant** on a space to add who occupied it and when (a business, a congregation, a resident).

On the building's page you'll see a floor plan and a "tenant in YEAR" table. On the map, zoom past ~16 to see spaces labelled with their tenants. Tagging a tenant (say *Food & drink*) lights up the space it occupied when you filter the map by that tag.

### Tracing from a scanned map (workbench)

The **workbench** lays a Sanborn fire-insurance sheet, an old plat or an aerial photo over the live data, so you can line things up and trace from it.

> **Scans are session-only drawing aids.** The image is opened straight from your computer and never uploaded, stored or shown to anyone else. It disappears when you close the page. Only the shapes you trace are saved.

| 1. Pin the scan | 2. Compare | 3. Trace |
|---|---|---|
| ![Aligning a scan by its corners](docs/images/workbench-align.png) | ![Swipe comparison](docs/images/workbench-swipe.png) | ![Tracing a footprint](docs/images/workbench-trace.png) |

*(The sheet in these screenshots is a synthetic sample, not a real Sanborn map.)*

1. **Workbench → Scan → Open a scan** (JPG/PNG). It appears over the map with four yellow corner handles.
2. **Align it:**
   - Drag each corner onto the matching street intersection; drag the blue centre handle to move the whole sheet.
   - Use the ⟲/⟳ and ±2 % buttons for fine rotation and scale.
   - Lower the opacity to see the streets underneath.
3. **Compare** in *Blend* or *Swipe* mode, or hold <kbd>F</kbd> to flicker the scan off and on.
4. Enter the **year the scan shows**. This moves the time slider and pre-fills dates on what you trace.
5. Switch to **Trace**:
   - Click to place vertices; they snap to existing corners. <kbd>Backspace</kbd> undoes and <kbd>Esc</kbd> clears.
   - Then either attach the shape to an existing page or create a new page (building, street, parcel…).
   - Pick a condition, a role (*footprint*, *centerline*…), dates and a citation.
6. **Save alignment file** downloads the corner positions as a small JSON file. Next time, open the same scan and choose **Load alignment** to pick up where you left off. The scan itself never leaves your computer.

Already georeferenced a sheet elsewhere (Map Warper, Allmaps…)? Paste its XYZ tile URL under **…or a tile layer**. It's also session-only.

### When a whole area's layout changed

![Area change: preview everything inside a polygon](docs/images/workbench-area.png)

The modern grid is a poor guide to the past. The lakefront was filled for the mill, the Grand Calumet River was re-channelled, the Toll Road and urban renewal erased blocks, and streets were vacated and re-platted. Decaynet handles this in several ways:

- **Everything has dated geometry.** Streets, parcels, shorelines (`water`) and terrain (`landform`) can each carry several shapes over time.
- **Ended things become ghosts.** You can still see the old grid after it's gone.
- **The basemap can be hidden** (Layers → Modern basemap → *Hidden*, or as the site default) when today's streets mislead.
- **The Area change tool:** draw around a cleared block or highway corridor, enter the year, preview everything standing inside, untick anything that survived, and end the rest in one step, with a condition (demolished / vacated…), a note and a citation. Nothing is deleted; it just becomes history.
- Then **trace the new layout** from a later scan or import it.

### Importing GIS data

**Workbench → Import** accepts a GeoJSON FeatureCollection in lon/lat (EPSG:4326), for example footprints from a city GIS, digitized parcels or a street grid.

1. Choose the file. Features are previewed in blue.
2. Pick the kind and role, which property holds the **name**, and optionally which properties hold the **start** and **end year** (e.g. `built`, `razed`).
3. Set default dates, a condition, a confidence level and a source.
4. **Import.** Each feature becomes a page with a dated shape.

Bulk tools (area change and import) need the *Bulk map tools* permission.

### Starter pages from OpenHistoricalMap & Wikidata

Rather than copying data across by hand, **Import** (needs *Bulk map tools*) pulls features **live** from
[OpenHistoricalMap](https://www.openhistoricalmap.org) and [Wikidata](https://www.wikidata.org) for an area you choose.
OpenHistoricalMap supplies dated footprints, streets, rail and water through its public Overpass API. Wikidata supplies names, inception and demolition dates, NRHP numbers, architects, styles and aliases through its SPARQL service. Both are CC0.

![Import preview: new pages and updates, on the map and in the list](docs/images/import-preview.png)

1. **Pick an area:** *Use visible map area*, or *Draw a box* by clicking two corners. Keep it to a few blocks or a neighborhood (about 10 km across at most).
2. **Choose sources and categories:** buildings (optionally including unnamed footprints), streets, railways, water, businesses, and neighborhoods/landmarks; Wikidata, optionally linking Commons images.
3. **Fetch preview.** The server queries both services, then:
   - **pairs them up:** an OHM feature tagged `wikidata=Q…`, a Wikidata point inside an OHM footprint, or a similar name close by. An unnamed OHM footprint can get its name from Wikidata this way.
   - **groups** street segments that share a name into one street;
   - **matches** each result against existing pages, by previous import ID, Wikidata ID, overlapping footprint, or a similar name nearby of a compatible kind.
4. **Review.** Every row shows exactly what would happen:
   - **new** (green): the page that would be created, with its dates, shape, names, attributes and tags;
   - **update** (amber): only the *gaps* it would fill on an existing page (missing dates, a shape if the page has none, new names, attributes it lacks, tags, links). Existing facts are **never overwritten**;
   - **up to date** (grey): already imported, nothing to add.

   You can rename, change the kind, switch a row between create, update and skip, opt into adding a second shape, filter, and click ⌖ to see a feature on the map.

   ![Updates only fill gaps](docs/images/import-preview-updates.png)
5. **Apply.** After a confirmation, everything is written in one transaction. Each fact is cited to an auto-created source ("OpenHistoricalMap, retrieved DATE" / "Wikidata, retrieved DATE"), and each page keeps a link to its OHM element or Wikidata item, so the next import recognises it instead of duplicating it.
6. **Undo** (moderators): *Recent imports* can delete the pages an import created. Additions it made to existing pages stay, and show up in the change log.

Notes:
- An OHM `end_date` sets the end of the page's lifespan, which turns it into a ghost on the map. It does **not** add a "demolished" condition, because the source doesn't say how something ended.
- OHM's public Overpass server allows only a couple of queries at a time per IP. The app retries politely, and re-previewing the same area within 10 minutes reuses the fetched data (matching is always re-run).
- Both services ask for a descriptive User-Agent; the app sends your site name and source URL.

### Anonymous tips

| Guest | Reviewer |
|---|---|
| ![The tip form](docs/images/tip-form.png) | ![Reviewing a tip](docs/images/tip-review.png) |

**For visitors:**
- Anyone can open **Tip** in the header, with no account needed.
- They can say what a tip is about (an existing page or free text), roughly when, and optionally leave contact details, pin a location and attach photos.
- Large photos are resized in the browser before sending.

**For reviewers** (*Review tips* permission):

![The tip queue](docs/images/tips-queue.png)

- Open **Tips**. The header badge counts open tips.
- Move tips through **new → reviewing → accepted / rejected / spam** and add private notes.
- **Link** a tip to an existing page, or **create a page** from it (a pinned location becomes a *speculative* point).
- **Add to media library**: copy a tip photo into public media as *depicting* a page. Rights are marked "unverified" until you set them.
- The **Source** box shows whether a captcha was passed, the IP (if the site records full IPs) and how many tips came from the same source.

Tips are written only by the app server, after the captcha, rate-limit and honeypot checks, so nobody can bypass them through the API. Photos go to a **private** storage bucket that reviewers read through short-lived signed links.

### Administration

**Site settings** (*Admin → Site settings*) replaces config files:

![Site settings](docs/images/admin-settings.png)

| Section | Settings |
|---|---|
| Identity | Site name, tagline, region, **source code URL** (see [License](#license)), About page text |
| Map | Default centre, zoom and year; earliest slider year; basemap tiles, attribution and fade behaviour |
| Accounts | Allow sign-ups; role given to new accounts |
| Tips | On/off, intro text, images (count and size), **IP mode**, **captcha**, rate limit |
| Secrets | Captcha secret key, IP-hash salt. Stored where only the server can read them, and never shown again |

**Tip privacy options:**
- **IP mode** `off`: nothing recorded, and no rate limiting.
- **IP mode** `hash` (the default): a salted one-way hash is kept for rate limiting only; nobody can read the IP.
- **IP mode** `full`: the IP is stored and shown to reviewers. Mention this in your privacy notice.

**Captcha setup:**
- **Cloudflare Turnstile:** create a widget, paste the *site key* in settings, paste the *secret key* under Secrets, then choose *Turnstile*.
- **hCaptcha:** the same steps with an hCaptcha site key and secret.

**Roles & permissions** (*Admin → Roles & permissions*):

![The roles × permissions matrix](docs/images/admin-roles.png)

Tick a box to grant a permission to a role, and add your own roles (e.g. "Archivist"). The database enforces the matrix through row-level security, so it holds even if someone calls the API directly. Defaults:

| Permission | Contributor | Editor | Moderator | Admin |
|---|:-:|:-:|:-:|:-:|
| Edit content (pages, facts, articles, tags on pages) | ✓ | ✓ | ✓ | ✓ |
| Upload media | ✓ | ✓ | ✓ | ✓ |
| Create tags | ✓ | ✓ | ✓ | ✓ |
| Review tips | | ✓ | ✓ | ✓ |
| Bulk map tools (area change, import) | | ✓ | ✓ | ✓ |
| Moderate (delete others' content, lock & feature articles) | | | ✓ | ✓ |
| Manage users | | | | ✓ |
| Manage site settings | | | | ✓ |

**Users** (*Admin → Users*):
- Change roles and suspend accounts. Suspended users can still read.
- Email addresses appear here when `SUPABASE_SERVICE_ROLE_KEY` is set.
- The last admin can't be demoted or suspended.

Everyone can manage their own profile, email and password at **Account**.

### Keeping quality up

| | |
|---|---|
| ![Maintenance](docs/images/maintenance.png) | **Maintenance** shows article status counts and work queues computed from the data: not on the map, no citations, no photos, thin article, no condition history, not connected to anything. |
| ![Timeline](docs/images/timeline.png) | **Timeline** is a city-wide chronology by decade: events, things built and demolished, and decline milestones. |
| ![Tags](docs/images/tags.png) | **Tags** shows the trait tree with usage counts. Contributors can add sub-traits as they tag. |

**Changes** lists every edit to prose and facts. Each page's **History** shows its revisions, every fact change and its article status transitions.

---

## How the data model works

Most wikis store pages. Decaynet stores **entities, components and time**, and pages are views over them.

| Layer | What it is | Tables / functions |
|---|---|---|
| **Entities** | Just an id, a kind, a slug and a lifespan | `entities` |
| **Components** | Narrow tables, one per kind of fact | `entity_names`, `entity_geometries`, `entity_states`, `entity_attributes`, `addresses`, `relations`, `entity_tags` |
| **Systems** | SQL functions that fold facts into an answer *as of a date* | `map_snapshot`, `entity_snapshot`, `entity_timeline`, `chronology`, `moments_near`, `building_spaces`, `tags_at`… |

**Every fact is temporal.** All component tables share one header (`LIKE internal.temporal_fact`):

```
valid_from, valid_from_precision   -- 1926 · 1920s · May 1926 · 1926-05-12
valid_to,   valid_to_precision     -- blank = still true
valid  (generated daterange)       -- the window, widened to its precision
confidence                         -- confirmed · probable · approximate · speculative · disputed
source_id, source_detail, note     -- citation + "p. 42"
```

- **Fuzzy windows:** "active until 1975" at year precision stays true for all of 1975. When facts overlap, the one that started most recently wins.
- **Nothing is overwritten.** A renaming adds a name row, a fire adds a condition row, and a move adds a geometry row.
- **Two clocks:** *valid time* (when it was true in Gary) lives on the facts; *record time* (when someone wrote it down) lives in `change_log` and `article_revisions`.
- **Building → space → tenant:** spaces are entities `part_of` a building, with polygons inside its footprint; tenants `occupy` spaces.
- **Tags** form a tree inside facets; tagging a sub-trait implies its ancestors, and tag assignments are dated.
- **Permissions:** every RLS policy calls `has_permission()`, which reads the roles × permissions tables.

Key RPCs:

| Function | Returns |
|---|---|
| `map_snapshot(at, kinds, bbox, ghosts, tag)` | GeoJSON of everything standing on a date (and ghosts), with names, condition and tenants as of then |
| `entity_snapshot(id, at)` / `entity_timeline(id)` / `entity_relations(id)` | One entity folded to a date / every fact in order / all edges with period-correct names |
| `moments_near(at, years)` / `chronology(from, to)` | Events and photos near a date / the city-wide chronology |
| `search_entities(q)` | Fuzzy search across current and historic names |
| `building_spaces(id, at)` / `add_space(...)` | Spaces and tenants of a building / validated space creation |
| `entities_in_area(...)` / `retire_area(...)` / `import_features(...)` | Workbench bulk tools |
| `match_import_candidates(...)` / `apply_import(...)` / `undo_import(...)` | OHM / Wikidata import: match, apply a reviewed plan, undo |
| `save_article(...)` / `set_article_status(...)` | Atomic revision + status transitions |

---

## Configuration reference

Environment variables (everything else is in **Admin → Site settings**):

| Variable | Required | Purpose |
|---|---|---|
| `PUBLIC_SUPABASE_URL` | yes | Supabase URL as **browsers** reach it |
| `PUBLIC_SUPABASE_ANON_KEY` | yes | Supabase anon key |
| `SUPABASE_SERVICE_ROLE_KEY` | for tips | Server-only. Needed to accept tips and to show emails in user admin. Never expose it |
| `SUPABASE_INTERNAL_URL` | no | How the **server** reaches Supabase, if different (e.g. `http://host.docker.internal:54321` or a Docker service name) |
| `ORIGIN` | Docker/prod | Public URL of the site (SvelteKit form CSRF check) |
| `ADDRESS_HEADER`, `XFF_DEPTH` | behind a proxy | Real client IPs for tips (`X-Forwarded-For`, `1`) |
| `BODY_SIZE_LIMIT` | no | Max request body (image default `25M`) |
| `PORT`, `HOST` | no | Listen address (image default `0.0.0.0:3000`) |
| `DATABASE_URL` | migrate | Postgres connection string for the migration runner |
| `SEED` | migrate | `1` loads the demo data into an empty database |

---

## Project layout

```
Dockerfile, docker-compose.yml   app image (adapter-node) + migration runner
docker/migrate.sh                idempotent migration runner (Supabase-compatible history)
supabase/migrations/             0001 foundation · 0002 components · 0003 articles · 0004 systems
                                 0005 security/audit/storage · 0006 vocabulary · 0007 tags
                                 0008 permissions/settings · 0009 tips · 0010 spaces/layout tools
                                 0011 session-only overlays + source link · 0012 external ids & import
supabase/seed.sql                Gary demo data
src/lib/map/style.ts             MapLibre layers for snapshots, ghosts, spaces, moments
src/lib/components/              TimeMachineMap, YearSlider, EntityPanel, Timeline, MiniMap,
                                 GeometryPicker, EntityPicker, TemporalFields, TagSelect, TagChips…
src/lib/server/                  db helpers, forms, markdown, service client, tips (captcha/IP)
src/lib/server/importers/        OpenHistoricalMap (Overpass) + Wikidata (SPARQL) fetch, combine, match, plan
src/routes/                      pages, /api endpoints, /workbench, /import, /tip(s), /admin
docs/images/                     screenshots used in this README
ROADMAP.md                       long-horizon tracker
```

---

## About the demo data

The seed has about 45 pages to show how the model works: Union Station, City Methodist, Hotel Gary / Genesis Towers, City Hall, the Palace, Emerson School, the Aquatorium, Gary Works, the 1919 steel strike, Mayor Hatcher and others.

- **Coordinates and shapes are approximate placeholders.** Building footprints are rectangles of plausible size, the spaces inside City Methodist and the Palace are schematic, and the lake shoreline and Grand Calumet River course are rough. All of them are flagged *approximate* or *speculative*.
- **Dates come from commonly cited public histories**, and uncertain ones are flagged. Several articles are deliberately marked *Needs sources*.
- The Maintenance page lists everything that still needs a citation, a photo or a traced footprint. Good primary sources:
  - the Calumet Regional Archives (IU Northwest)
  - Sanborn maps
  - city directories
  - the Post-Tribune and the Gary American

---

## Roadmap & contributing

The long-horizon plan, open questions and decision log are in **[ROADMAP.md](ROADMAP.md)**. Pull requests should:

1. add new SQL as a **new migration** (never edit an applied one),
2. pass `npm run check`,
3. keep the [data model](#how-the-data-model-works) rule: facts are temporal rows, and systems are SQL.

---

## License

Copyright © 2026 the Decaynet contributors.

This program is free software: you can redistribute it and/or modify it under the terms of the **GNU Affero General Public License** as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but **without any warranty**; without even the implied warranty of merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for the full text.

**If you run Decaynet for others over a network, AGPL §13 requires you to offer them the source of the version you run.** The site footer, the About page and the map attribution link to the **Source code URL** in *Admin → Site settings*. If you modify the code, point that URL at your fork.

Content contributed to a Decaynet site (articles, facts, media) is separate from the software and is governed by that site's own terms. Map data © OpenStreetMap contributors (ODbL) where the modern basemap is shown. Imported OpenHistoricalMap and Wikidata data is CC0. Linked Wikimedia Commons images keep their own licenses.
