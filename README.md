# Decaynet

**A time-machine map and regional wiki for Gary, Indiana.** Drag a slider from 1890 to today and watch streets get laid out, buildings rise, change hands, empty out, burn and disappear. Every place, person, business, photo and event is a wiki page, and every fact about it has a date.

Built with **SvelteKit 2 / Svelte 5**, **Supabase** (Postgres 17 + PostGIS, Auth, Storage) and **MapLibre GL**.

---

## The idea: data-oriented history

Most wikis store *pages*. Decaynet stores **entities, components, and time**, and the pages are views over them.

| Layer | What it is | Where |
|---|---|---|
| **Entities** | Just an id, a `kind` (street, building, person, organization, event, media…), a slug and a lifespan. | `entities` |
| **Components** | Narrow tables, one per kind of fact: names, shapes, condition, attributes, addresses, relations, tags. | `entity_names`, `entity_geometries`, `entity_states`, `entity_attributes`, `addresses`, `relations`, `entity_tags` |
| **Systems** | Pure SQL functions that fold the facts into an answer *as of a date*. | `map_snapshot`, `entity_snapshot`, `entity_timeline`, `chronology`, `moments_near`, `tags_at`… |

### Every fact is temporal

All component tables are created `LIKE internal.temporal_fact`, so they share one header:

```
valid_from, valid_from_precision   -- 1926 · 1920s · May 1926 · 1926-05-12
valid_to,   valid_to_precision     -- blank = still true
valid  (generated daterange)       -- the window, expanded to its precision
confidence                         -- confirmed · probable · approximate · speculative · disputed
source_id, source_detail, note     -- citation + "p. 42"
```

* **Fuzzy dates are first-class.** "Active until 1975" (year precision) stays true for all of 1975; "1950s" covers the decade. Contributors type `c. 1926`, `1920s` or `May 1926` and the app works out the precision and confidence.
* **Nothing is overwritten.** A renamed street gets a second name row, a fire gets a new condition row, and a moved building gets a new geometry row. The old ones are end-dated, not deleted.
* **Resolution rule:** a fact applies on date *D* when *D* is inside its window; if several overlap, the most recently started wins.
* **Two clocks.** *Valid time* (when something was true in Gary) lives on the facts. *Record time* (when someone wrote it down) lives in `change_log` and `article_revisions`. Both are shown on each page's History tab.

Because the street is itself an entity, an address like *577 Washington St* is stored as `house_number + street_id`, and the rendered address follows the street's name in whatever year you are viewing.

### What's tracked over time

* **Streets**: centerlines, names, extents (`entity_geometries`, `entity_names`)
* **Buildings & sites**: footprints/points, condition (active → vacant → abandoned → ruin → demolished), addresses, attributes (architect, style, floors, cost)
* **Occupants**: `occupies`, `owns`, `resides_at`, `held_office` relations with their own date windows and qualifiers (`office=Mayor`)
* **Media**: photos, postcards, maps, clippings, video, audio. Each has a capture date, a `depicts` relation dated to the *period shown*, and an optional camera viewpoint + bearing. Files live in the Supabase Storage `media` bucket.
* **Notable events**: fires, strikes, closings, elections, film shoots, with an event type, a date range and an `occurred_at` / `affected` location
* **Article status**: stub → draft → needs sources → needs review → good → featured, recorded as transitions in `article_status_events`
* **Tags & sub-traits**: see below

### Tags with sub-traits

Tags form a tree inside **facets** (*Business type*, *Architecture*, *Topic*, *Media subject*, *Era*):

```
Business type › Food & drink › Restaurant › Soul food
Topic         › Urban decay  › Abandonment
```

* Tag the most specific trait; the ancestors are **implied** (shown as dashed chips). Filtering by *Food & drink* finds the soul-food diner.
* Tagging is just another temporal component, so a storefront can be a *Bar* 1950–1972 and a *Church* afterwards. `entities_tagged('bar-tavern', '1960-07-01')` answers "every bar in 1960".
* Any entity can be tagged: businesses (business type), buildings (architecture), media (subject), articles/events (topic, era).
* Contributors can create new sub-traits inline while tagging; moderators curate the tree.
* The map has an **Only things tagged…** filter ("show every movie theater in 1955").

### Buildings, spaces and tenants

Buildings have real polygon **footprints**. Inside a footprint you draw **spaces** (storefronts, suites, halls, floors) as their own polygons. `add_space()` rejects any space that extends more than 2 m outside the footprint. Tenants (businesses, congregations, residents) **occupy a space** over time:

```
Hotel Gary (building, footprint polygon)
 └─ Broadway storefront (space, floor 1, unit 101)
      ├─ occupied by Barbershop A   1930–1940
      └─ occupied by Church B       1980–1995
```

Zoom past ~16 on the map and spaces appear inside their buildings, labelled with whoever occupied them in the chosen year (or "vacant"). A tag filter such as *Food & drink* also lights up the spaces its tenants occupied.

### When the whole layout was different

The modern street grid is a poor guide to 1906 or 1950: the shoreline moved as the mill was filled into the lake, the Grand Calumet River was re-channelled, the Toll Road and urban renewal erased blocks, and streets were vacated and re-platted. The model handles this as follows:

* **Everything has dated geometry.** Streets, parcels, shorelines (`water`) and terrain (`landform`) can each have several shapes over time, so the 1910 shoreline and the 1960 shoreline are both stored.
* **Lost things become ghosts** (dashed) after their lifespan ends, so you can still see the old grid.
* **Basemap modes** (*fade with time*, *always*, *hidden*) let you drop today's map entirely when it misleads.
* **Workbench area tool:** draw around a cleared block or a highway corridor, pick the year, preview what's inside, and end it all at once (with a citation). Nothing is deleted; it just becomes history.
* **Overlays** (Sanborn sheets, plats, aerials) supply the historical layout to trace from.
* Planned: named *layout epochs* and a street-segment model (see [ROADMAP.md](ROADMAP.md)).

### Systems (RPCs)

| Function | Returns |
|---|---|
| `map_snapshot(at, kinds, bbox, ghosts, tag)` | GeoJSON of everything standing on a date, colored by condition. Demolished places can be drawn as dashed "ghosts". |
| `moments_near(at, years)` | Events and dated photos within ±N years, located by their own geometry or what they occurred at or depict. |
| `entity_snapshot(id, at)` | One entity folded to a date: name, condition, address, attributes, connections, media. |
| `entity_timeline(id)` | Every fact about an entity, chronologically. |
| `entity_relations(id)` | The edge list in both directions, with the other side's *period-correct* name. |
| `chronology(from, to)` | City-wide feed: events, things built/demolished, decline milestones. |
| `search_entities(q)` | Fuzzy (trigram) search across current **and historic** names. "Genesis Towers" finds Hotel Gary. |
| `tags_at(id, at)` / `entities_tagged(tag, at)` | Tag lookups including implied ancestors / descendant traits. |
| `save_article(...)` / `set_article_status(...)` | Atomic revision + status-transition writes. |
| `building_spaces(id, at)` / `tenants_at(space, at)` / `add_space(...)` | Spaces inside a building, their tenants on a date, validated creation. |
| `entities_in_area(geojson, at)` / `retire_area(...)` / `import_features(...)` | Workbench bulk tools. |
| `has_permission(p)` / `my_permissions()` | The single permission check behind every RLS policy. |

Views: `facts` (all components behind one header), `entity_health` (derived maintenance issues), `entity_cards`, `tag_index`, `tag_tree`, `recent_activity`.

---

## The app

| Route | |
|---|---|
| `/` | **Time machine.** Year slider with play, decade jumps, ←/→ keys and an event-density histogram. Layer toggles, ghosts, tag filter, historical raster overlays, events ±5 yrs. Click anything to see it *as of that year*. The URL (`?y=1955&sel=…&c=lon,lat,zoom&tag=…`) is shareable. |
| `/e/[slug]` | Wiki page: article, timeline, connections, tags, media gallery, footnoted sources, a snapshot box with its own year slider, and a minimap of footprints over time. |
| `/e/[slug]/edit` | Markdown editor with `[[slug]]` / `[[slug\|label]]` wiki links (red links for missing pages), preview, status and edit summary. |
| `/e/[slug]/facts` | Structured editor for every component: names, condition, addresses, attributes, relations, tags, shapes (draw on a map or paste GeoJSON). Edit dates and citations on any fact. |
| `/e/[slug]/history` | Revisions, fact change log, status history. |
| `/new`, `/media/new` | Create pages; upload media straight to Supabase Storage. |
| `/browse`, `/search`, `/timeline`, `/tags`, `/tags/[slug]` | Discovery. |
| `/changes` | Recent changes across prose and facts. |
| `/maintenance` | Article-status breakdown and auto-detected work queues: not mapped, unsourced, no photos, thin article, orphan… |
| `/sources`, `/layers` | Citations; historical map overlays (XYZ tiles or pinned scans) with the period they depict. |
| `/workbench` | **Editor tooling.** Georeference a scanned Sanborn sheet by dragging its corners (plus rotate/scale nudges); compare it with the data by blend, swipe or flicker (hold <kbd>F</kbd>); trace footprints and streets over it with vertex snapping; retire whole areas; import GeoJSON from GIS. |
| `/tip` | Public, anonymous tip form (optional photos and map pin). |
| `/tips` | Tip review queue: triage, notes, link or create pages, promote photos to the media library. |
| `/account`, `/u/[id]` | Profile, email and password; public contribution history. |
| `/admin/settings`, `/admin/users`, `/admin/roles` | Site settings, user roles and suspension, and the roles × permissions matrix. |

### Accounts & permissions

Permissions are rows, roles are rows, and admins edit the matrix at **/admin/roles**. Every RLS policy goes through `has_permission()`:

| Permission | Contributor | Editor | Moderator | Admin |
|---|:-:|:-:|:-:|:-:|
| Edit content (pages, facts, articles, tag assignments) | ✓ | ✓ | ✓ | ✓ |
| Upload media | ✓ | ✓ | ✓ | ✓ |
| Create tags | ✓ | ✓ | ✓ | ✓ |
| Review tips | | ✓ | ✓ | ✓ |
| Manage overlays | | ✓ | ✓ | ✓ |
| Bulk map tools (area change, import) | | ✓ | ✓ | ✓ |
| Moderate (delete others' content, lock/feature) | | | ✓ | ✓ |
| Manage users | | | | ✓ |
| Manage site settings | | | | ✓ |

Everyone can read, and *Reader* is a signed-in read-only role. You can add custom roles. The first account becomes admin, and the last admin can't be demoted or suspended. Suspended users keep read access only.

### Site settings

Everything you'd otherwise put in a config file lives in the `site_settings` row and is edited at **/admin/settings**: the site name and tagline, region, the map's default centre, zoom and year, the earliest year on the slider, the basemap tile URL, attribution and fade behaviour, open or closed sign-ups and the default role, and all the tip options. Secrets (captcha secret key, IP-hash salt) go in a table only the server can read; the UI shows whether they're set but never the values.

### Anonymous tips

Guests can send a tip at **/tip** without an account. It can include a subject, the page it's about, a rough date, contact details, a map pin and photos. The settings control:

* **Images:** on or off, a maximum count and a maximum size. Large photos are downscaled in the browser first. Files go to a *private* `tips` bucket that only reviewers can read, through signed URLs.
* **Source IP:** *off*, *salted hash* (default: enough for rate limiting, but nobody can read the IP), or *full* (stored and shown to reviewers).
* **Captcha:** none, Cloudflare Turnstile or hCaptcha, verified on the server.
* **Rate limit:** tips per IP per hour. There is also a honeypot field against bots.

Tips are written only by the app server, using the service-role key, after those checks, so nobody can bypass them through the API. Reviewers with *Review tips* triage them at **/tips** (new → reviewing → accepted / rejected / spam). They can link a tip to a page or create one from it (the pin becomes a speculative location), and promote its photos into the media library as *depicts* the page.

---

## Running it locally

Requires Node 20+ and Docker (for the Supabase local stack).

```bash
npm install
npx supabase start            # Postgres+PostGIS, Auth, Storage; applies migrations + seed
cp .env.example .env          # paste the API URL, anon key and service-role key from `supabase start`
npm run dev                   # http://localhost:5173
```

Create an account at `/login`. Email confirmation is off locally, and the first user is admin.

`npm run db:reset` rebuilds the database from `supabase/migrations` and `supabase/seed.sql`. `npm run check` runs svelte-check.

### Deploying

1. Create a Supabase project and run `npx supabase link` then `npx supabase db push`. Load `supabase/seed.sql` from the SQL editor if you want the starter data.
2. In Auth settings, add `https://your-domain/auth/callback` to the redirect URLs.
3. Set `PUBLIC_SUPABASE_URL` and `PUBLIC_SUPABASE_ANON_KEY` on your host, plus the server-only `SUPABASE_SERVICE_ROLE_KEY` (needed for tips and for showing emails in user admin). If you deploy with `adapter-node`, raise `BODY_SIZE_LIMIT` (for example `BODY_SIZE_LIMIT=25M`) so tips with photos and GeoJSON imports fit. `adapter-auto` covers Vercel, Netlify and Cloudflare; swap in `@sveltejs/adapter-node` for a VPS.
4. The basemap uses the public OpenStreetMap tile server, which is fine for development. For production traffic, point `baseStyle()` in `src/lib/map/style.ts` at your own or a commercial tile provider, per the [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/).

### Project layout

```
supabase/migrations/   0001 foundation · 0002 components · 0003 articles · 0004 systems
                       0005 security/audit/storage · 0006 vocabulary · 0007 tags
                       0008 permissions/settings · 0009 tips · 0010 spaces/layout tools
supabase/seed.sql      starter Gary data
src/lib/map/style.ts   MapLibre style + layers for snapshots, ghosts, moments
src/lib/components/    TimeMachineMap, YearSlider, EntityPanel, Timeline, MiniMap,
                       GeometryPicker, EntityPicker, TemporalFields, TagSelect, TagChips…
src/lib/time.ts        fuzzy-date parsing/formatting
src/routes/            pages + /api endpoints (snapshot, moments, entity, search)
```

---

## About the seed data

The seed includes about 40 entities (Union Station, City Methodist, Hotel Gary/Genesis Towers, City Hall, the Palace, Emerson School, the Aquatorium, Gary Works, the 1919 steel strike, Mayor Hatcher, and others) to show how the model works.

* **Coordinates are approximate.** They were placed by eye against the OSM basemap and are flagged `confidence = 'approximate'`. Building footprints are rectangles of plausible size, and the spaces inside City Methodist and the Palace are schematic splits. Broadway's pre-1920 extent and the Grand Calumet River course are placeholders.
* **Dates come from commonly cited public histories.** Uncertain ones are marked `approximate` or `speculative` with a note. Several articles are deliberately marked *Needs sources*.
* The Maintenance page will list everything that still needs a citation, a photo or a precise footprint. Primary sources such as the Calumet Regional Archives at IU Northwest, city directories, Sanborn maps and the Post-Tribune are the place to start.

## Roadmap

The long-horizon plan, open questions and decision log are in **[ROADMAP.md](ROADMAP.md)**.
