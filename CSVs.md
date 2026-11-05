# Importing your own data from spreadsheets

A spreadsheet is the fastest way to get many pages in at once: every business
on a block from a city directory, the residents of a street from a census, a
business followed through ten years of directories. **Import → Spreadsheet**
(`/import/spreadsheet`) reads it, matches each row to what the wiki already has,
shows you the result, and only writes it when you've checked it. The whole
import can be undone.

You need the *Bulk map tools* and *Edit content* permissions. Undo needs
*Moderate*.

- [Ground rules for accurate imports](#ground-rules-for-accurate-imports)
- [Quick start](#quick-start)
- [The file](#the-file)
- [Columns](#columns)
- [Dates](#dates)
- [Timed facts](#timed-facts)
- [Associations (links)](#associations-links)
- [How rows are matched](#how-rows-are-matched)
- [Recipes](#recipes)
- [Importing again, and undoing](#importing-again-and-undoing)
- [Reference: facts and link types](#reference-facts-and-link-types)
- [Troubleshooting](#troubleshooting)

---

## Ground rules for accurate imports

1. **One row is one thing, seen in one source, at one time.** "Kresge's, 512
   Broadway, in the 1925 directory" is a row. Kresge's in the 1930 directory is
   another row (see [Timed facts](#timed-facts)).
2. **Cite the document, not the sheet.** The import asks what the sheet was
   *made from* (the directory, census or map) and cites that on everything it
   adds. The sheet is just your transcription: it isn't uploaded as a file or
   stored anywhere, and it's cleared once imported.
3. **Say where in the document.** A *Page* (or *Entry*, *Frame*) column becomes
   the citation's detail, so anyone can check a fact against the original.
4. **Copy what the source says.** Names as printed, addresses as printed (the
   street's old name is fine: it's matched against every name the street has
   had). Don't modernise or guess; put doubts in a *Note* column.
5. **Leave unknown dates blank** rather than guessing; use a decade ("1920s")
   when that's all you know.
6. **Read the preview.** Rows with something to check are marked amber. Fix the
   sheet and preview again, or untick the row.

## Quick start

1. Open **Import → Spreadsheet** and click **Download a template**:

   ```csv
   Name,Address,Unit,Listed in,From,Until,Category,Other names,Page,Note
   "Kresge's",512 Broadway,,1925,,,Retail,"S. S. Kresge Co.",214,
   Joe's Diner,520 Broadway,2,1925,,,Food & drink,,214,Lunch counter
   Gary Hotel,600 Broadway,,,1927,1975,Lodging,Hotel Gary,231,
   ```

2. Fill it in, in any spreadsheet program, and save it as CSV (UTF-8). Or copy
   the cells and paste them straight into the box.
3. Check the column guesses (step 2 on the page).
4. Under **For every row**, pick what the sheet was **made from**. Pick it from
   the library, or choose *New source…* and fill in the title and kind. Then set
   what the pages are (organizations, people…), the directory's year if the rows
   have no dates of their own, and how they're linked to buildings.
5. **Preview**, check the amber rows, and **Import**.

## The file

- **CSV or TSV**, or cells pasted from Excel, LibreOffice or Google Sheets (they
  paste as tab-separated). The separator is detected from the first line:
  tab, `;` or `,`.
- **Quotes** work as in any CSV: `"Smith, Jones & Co."` keeps its comma, and a
  doubled `""` is a quote inside a quoted cell. Line breaks inside quotes are fine.
- **The first row is the column names**, unless you untick *The first row holds
  the column names* (then the columns are called Column 1, 2…).
- **Blank rows, and rows with no name, are skipped**, so section headings and
  spacer lines from a directory transcription do no harm.
- **Up to 2,000 rows** per import. Split bigger sheets by block or by page range.
- Save as **UTF-8** so accents survive (Excel: *CSV UTF-8*).

## Columns

Each column is guessed from its header; any of them can be changed, or set to
*Ignore*. The next sheet with the same headers keeps your choices.

| Column | Headers it's guessed from | What it does |
|---|---|---|
| **Name** *(required)* | Name, Business, Company, Firm, Organization, Occupant, Tenant, Person | The page's title. Used to find an existing page. |
| **Address** | Address, Location, Street | Finds the building at that address in that year. Kept on the page if no building matches. |
| **Unit / suite** | Unit, Suite, Room, Apt, Office, Store | Finds the storefront or suite inside the building. Also read from the end of an address: `512 Broadway, Suite 3`, `Rm 201`, `#3`. For a row that *is* a storefront (Kind `space`), it's the storefront's own number. |
| **Building** | Building, Place, Premises | The building (or site, parcel, storefront) by its page name, slug or `/e/…` link. Wins over the address. |
| **Listed in** | Year, Listed, Directory, Date, Seen | One year (or date) the row was true. See [Dates](#dates). |
| **From** / **Until** | From, Start, Opened, Since, Established, Founded / Until, To, End, Closed, Moved | A span instead of one year. |
| **Kind** | Kind, Page kind | `organization`, `person`, `building`, `space`… (the id or the label). Otherwise the page-wide setting. |
| **Link as** | Link, Relation, Role | `occupies`, `lived at` (`resides_at`), `owns`, `is in` (`located_in`). Otherwise the page-wide setting. |
| **Tags** | Tags, Category, Type, Trade, Business type | Existing tags by label or slug, several separated by `;`. Unknown tags are flagged and skipped. |
| **Other names** | AKA, Also known as, Other names, DBA, Formerly | Alternate names, separated by `;`. |
| **Summary** | Summary, Description, About | The one-line summary of a **new** page (an existing page's summary is left alone). |
| **Note** | Note, Notes, Comment, Remarks | A note on the link (or on the kept address, for an unplaced row). |
| **Source detail** | Page, P, Pg, Entry, Citation, Reference, Folio, Frame | Where in the source: cited with every fact the row adds. A bare number reads as a page: `214` → "p. 214". |
| **Latitude** / **Longitude** | Lat, Latitude / Lon, Lng, Long, Longitude | A map point, in decimal degrees (WGS 84): for a place row, or a new building when no building matches. |
| **A fact** | the fact's label or id, e.g. *Employees*, *Industry*, *Occupation*, *Website* | A dated fact on the page. See [Timed facts](#timed-facts) and the [list of facts](#reference-facts-and-link-types). |

Lists (*Tags*, *Other names*) split on `;`, or on `|` or `,` when there's no `;`.

## Dates

A date cell can be written any way a historian would:

| You write | It means |
|---|---|
| `1926` | the year 1926 |
| `1926-05` · `May 1926` | May 1926 |
| `1926-05-12` · `May 12, 1926` | that day |
| `1920s` | the decade 1920–1929 |
| `1800s` · `19th century` | the century (`2000s` is the decade 2000–2009; write `21st century` for the century) |
| `c. 1926` · `ca 1926` · `~1926` · `1926?` | read as 1926; say how sure you are with the **Confidence** setting |

What a row's dates do:

| The row has | The link (and the row's facts) hold | A **new** page's lifespan |
|---|---|---|
| **Listed in** only (or no dates, with *Listed in* set for the sheet) | in that year | left unknown |
| **From** and/or **Until** | from … until … | from … until … |
| nothing at all | undated | left unknown |

A directory listing says a business was there *that year*, not when it opened,
so **Listed in** never sets a lifespan. Use **From / Until** when the source
gives opening or closing dates.

## Timed facts

Every fact column is dated with the row's dates. To record a fact that changes,
**write one row per time**, with the same name:

```csv
Name,Address,Listed in,Employees,Page
Gary Screw & Bolt,1200 Madison St,1925,140,88
Gary Screw & Bolt,1200 Madison St,1930,210,95
Gary Screw & Bolt,1250 Madison St,1935,180,102
```

This makes **one** page for Gary Screw & Bolt (rows with the same name and kind
in one sheet share a page; the preview says "same page as row 2") with:

- *Employees*: 140 in 1925, 210 in 1930, 180 in 1935, each cited to its page
- *occupies* 1200 Madison St in 1925 and in 1930, and 1250 Madison St in 1935

The page's timeline and the map's year slider then show each fact in its year.
The same works across several sheets: import the 1930 directory later and its
rows match the page the 1925 import made.

For a fact over a span, use **From / Until** on that row instead of *Listed in*.

## Associations (links)

Each row can make **one dated link to a place**, the building, site, parcel or
storefront it was in:

- **Which place.** In order:
  1. A **Building** column: a page name (any case, close spellings found), a
     slug, or a `/e/…` link.
  2. The **Address**: the building that had that address in that year. House
     numbers are matched against every name the street has had, so `512 Main St.`
     finds a building on a street since renamed. `W. 5th Ave` equals
     `West 5th Avenue`. An address recorded only in other years still matches,
     flagged.
  3. With a **Unit**, the storefront or suite with that name or unit number
     inside it.
  4. Otherwise, the preview lets you **choose** the building, or make a **new
     map point** (see [Places not found](#places-not-found)).
- **Which link.** The page-wide *Linked to the building as* setting, or a
  per-row **Link as** column:

  | Link as | Links | to |
  |---|---|---|
  | `occupies` | an organization or person | a building, site, parcel or space |
  | `lived at` (`resides_at`) | a person | a building, parcel or space |
  | `owns` | a person or organization | a building, site, parcel or space |
  | `is in` (`located_in`) | anything | a site or parcel |

  A link that doesn't fit (a business that "lived at") is flagged in the
  preview.
- **When.** The row's dates (see [Dates](#dates)).
- **Rows that are places themselves** (Kind `building`, `site`…) don't link
  anywhere. They get their own map point from *Latitude / Longitude*, and their
  address. A **`space`** row with a *Building* is made *part of* that building
  (a storefront listed by number).

Links between two pages that aren't places (a person *worked for* a company,
a lodge *member of* a federation, someone *took part in* an event) can't come
from a sheet yet. Add them on the page under **Edit facts → Relations**.

### Places not found

- **Pick it in the preview**: *choose…* on the row, then search for the building.
- **A new map point**: with *Addresses that match no building become new map
  points* ticked, a row with *Latitude / Longitude* makes a building there (named
  by its address, marked approximate; the same address twice is one building).
  Optionally, tick the OpenStreetMap lookup to find coordinates for addresses.
  It uses **today's numbering**, which may have changed since, so check the
  results; only the first 25 addresses per preview are looked up, about one a
  second.
- **Leave it unplaced**: the row's address is kept on its page, so address
  search finds it, and you can place it later.

## How rows are matched

- **Existing pages.** A page of the same kind with the row's name, or with that
  name among its other names, is used rather than making a second one. A close
  spelling ("Kresges") is *offered*, not chosen: pick it in the row's *Page*
  menu if it's the same.
- **Two different things with one name** in one sheet (two unrelated "Joe's
  Diner"s) would share a page. Tell them apart in the name: "Joe's Diner
  (Broadway)", "Joe's Diner (Fifth Ave)".
- **Tags** must exist already (add them under *Tags* first). Unknown ones are
  shown with a `?` and skipped.

## Recipes

The names and addresses below are made up for illustration.

**A block from a city directory.** Kind *organization*, Listed in *1925*, Link
as *occupies*, made from the 1925 city directory.

```csv
Name,Address,Category,Page
F. W. Woolworth Co.,532 Broadway,Retail,214
Gary State Bank,504 Broadway,Finance,214
"Kaplan, Morris, tailor",518 Broadway,Retail,215
```

**Residents from a census.** Kind *person*, Link as *lived at*, made from the
1930 census sheets for the district (one source per enumeration district works
well; the sheet number goes in *Page*).

```csv
Name,Address,Listed in,Occupation,Page
John Kowalski,1712 Adams St,1930,Steelworker,4A
Mary Kowalski,1712 Adams St,1930,,4A
```

**One business through the years.** See [Timed facts](#timed-facts).

**Buildings from a list with coordinates.** Kind *building* (illustrative values):

```csv
Name,Address,From,Until,Latitude,Longitude,Page
Liberty Garage,1440 Washington St,1924,1961,41.5941,-87.3389,12
```

Each becomes a page with a map point and its address. Trace the footprint
later in the workbench.

**Storefronts of a building, by number.** Kind *space*: each row becomes a
storefront *part of* the building, with its unit number.

```csv
Name,Building,Unit,From
North store,Gary State Bank Building,101,1925
South store,Gary State Bank Building,102,1925
```

To draw their outlines at the same time, paste a GeoJSON of the storefronts
under the building's **Edit facts → Spaces** instead. Each area becomes a space,
with a row for its title, first name, address, unit and floor.

## Importing again, and undoing

- **Preview again before importing again.** The preview matches rows to the
  pages the last import made, so a second import adds to them rather than
  duplicating them.
- **Nothing is added twice to a page.** An identical link (same place, same
  dates), other name, tag, fact (same value, same dates) or kept address is
  skipped.
- **Undo** (moderators, under *Recent spreadsheet imports*) deletes the pages
  the import created, and the links, names, tags, facts and addresses it added
  to existing pages. The new source it may have created stays in the library.
- The import record keeps counts and the ids of what was added, never the
  sheet's rows.

## Reference: facts and link types

The defaults; *Admin → Vocabulary* may add more. Any fact can be mapped to any
column, but it's meant for the kinds listed.

| Fact | Value | For |
|---|---|---|
| Employees | number | organizations |
| Industry | text | organizations |
| Occupation | text | people |
| Website | link | anything |
| Wikidata ID | text | anything |
| Architect (name as recorded) | text | buildings, sites |
| Architectural style | text | buildings |
| Capacity / seats | number | buildings, sites |
| Construction cost | number | buildings, sites, infrastructure |
| Floors | number | buildings |
| Floor area | number | buildings, spaces |
| Height | number | buildings, infrastructure |
| Primary material | text | buildings, infrastructure |
| NRHP reference # | text | buildings, sites, districts |
| Owner of record | text | buildings, sites, parcels |
| Parcel number | text | parcels, buildings |
| Use | text | buildings, sites, parcels |
| Floor | number | spaces |
| Unit / suite | text | spaces |
| Area | number | districts, sites, parcels |
| Population | number | districts |
| Lanes · Surface | number · text | streets |
| Route designation | text | streets, infrastructure |
| Casualties | number | events |

Numbers may have thousands separators (`1,200`). A cell that isn't a number,
for a number fact, is flagged and skipped. Yes/no facts read `yes`, `y`, `true`,
`1` and `x` as yes.

Link types are in [Associations](#associations-links).

## Troubleshooting

| The preview says | What to do |
|---|---|
| *no building called "…"* | Check the spelling against the page title, or use its `/e/…` link. |
| *no storefront "5" in … : linked to the building* | Add the storefront (Edit facts → Spaces), or leave it on the building. |
| *… has that address only in other years* | The building's address record starts or ends at another time. Check it, or pick the building by hand. |
| *"lived at" doesn't link an organization to a building* | Use another *Link as* (a business *occupies*), or check the row's Kind. |
| *can't read the start "…"* | Write the date in one of the [forms above](#dates). |
| *unknown kind "…"* | Use a kind's id or label (organization, person, building, space…). |
| *Employees "about 40" isn't a number* | Write `40`, and say "about" with the Confidence setting or a Note. |
| *not looked up (only the first 25 addresses are)* | Import in smaller sheets, or add Latitude / Longitude columns. |
| **Import** stays greyed out | Pick what the sheet was *made from* (step 3). |
