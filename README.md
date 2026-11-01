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
| `/sources`, `/layers` | Citations; georeferenced map overlays (Sanborn sheets, aerials) as XYZ tiles with the period they depict. |

### Permissions (RLS)

* Everyone can read.
* Signed-in **contributors** can add and edit facts, pages, tags and media.
* **Moderators** can delete anything, lock articles, mark articles *featured*, edit the vocabulary and manage overlays. Contributors can delete only rows they created.
* **Admins** manage roles. The first account on a fresh install becomes admin.

---

## Running it locally

Requires Node 20+ and Docker (for the Supabase local stack).

```bash
npm install
npx supabase start            # Postgres+PostGIS, Auth, Storage; applies migrations + seed
cp .env.example .env          # paste the API URL and anon key printed by `supabase start`
npm run dev                   # http://localhost:5173
```

Create an account at `/login`. Email confirmation is off locally, and the first user is admin.

`npm run db:reset` rebuilds the database from `supabase/migrations` and `supabase/seed.sql`. `npm run check` runs svelte-check.

### Deploying

1. Create a Supabase project and run `npx supabase link` then `npx supabase db push`. Load `supabase/seed.sql` from the SQL editor if you want the starter data.
2. In Auth settings, add `https://your-domain/auth/callback` to the redirect URLs.
3. Set `PUBLIC_SUPABASE_URL` and `PUBLIC_SUPABASE_ANON_KEY` on your host. `adapter-auto` covers Vercel, Netlify and Cloudflare; swap in `@sveltejs/adapter-node` for a VPS.
4. The basemap uses the public OpenStreetMap tile server, which is fine for development. For production traffic, point `baseStyle()` in `src/lib/map/style.ts` at your own or a commercial tile provider, per the [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/).

### Project layout

```
supabase/migrations/   0001 foundation · 0002 components · 0003 articles · 0004 systems
                       0005 security/audit/storage · 0006 vocabulary · 0007 tags
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

* **Coordinates are approximate.** They were placed by eye against the OSM basemap and are flagged `confidence = 'approximate'`. Broadway's pre-1920 extent is illustrative only.
* **Dates come from commonly cited public histories.** Uncertain ones are marked `approximate` or `speculative` with a note. Several articles are deliberately marked *Needs sources*.
* The Maintenance page will list everything that still needs a citation, a photo or a precise footprint. Primary sources such as the Calumet Regional Archives at IU Northwest, city directories, Sanborn maps and the Post-Tribune are the place to start.

## Ideas for next steps

* Bulk import from city directories (CSV: year, name, address → occupancy relations)
* Georeferenced Sanborn and aerial overlay library
* Vector-tile endpoint (`ST_AsMVT`) once the dataset outgrows GeoJSON snapshots
* Side-by-side "then / now" compare mode, photo viewpoint cones on the map
* Talk pages / comment threads per fact
