import { error, json } from "@sveltejs/kit";
import { loadSettings } from "$lib/server/db";
import { osmLookup } from "$lib/server/geocode";
import {
  linesOf,
  splitCrossing,
  type CrossingHit,
  type CrossingLookup,
  type CrossingSide,
  type LL,
} from "$lib/map/crossings";
import type { RequestHandler } from "./$types";

type Page = { id: string; slug: string; name: string; shapes: number };
type WikiRow = {
  lon: number;
  lat: number;
  a: { slug: string; name: string };
  b: { slug: string; name: string };
  gap_m: number;
  then: boolean;
};
type Wiki = {
  hits: WikiRow[];
  a: { pages: Page[] };
  b: { pages: Page[] };
  suggest: { a: string[]; b: string[] };
  nearest: { lon: number; lat: number; gap_m: number } | null;
  lines: { a: GeoJSON.Geometry | null; b: GeoJSON.Geometry | null };
};

/** At most this many points of each street's lines go back to be drawn, and only near the spot. */
function drawable(
  lines: LL[][],
  at: LL | null,
  side: "a" | "b",
  from: "wiki" | "osm",
): GeoJSON.Feature[] {
  // a line passing near (its box overlapping ~3 km round the spot: a long straight street has
  // no points near it, only its ends)
  const near = (l: LL[]) => {
    if (!at) return true;
    const xs = l.map((p) => p[0]);
    const ys = l.map((p) => p[1]);
    return (
      Math.min(...xs) < at[0] + 0.04 &&
      Math.max(...xs) > at[0] - 0.04 &&
      Math.min(...ys) < at[1] + 0.03 &&
      Math.max(...ys) > at[1] - 0.03
    );
  };
  const out: LL[][] = [];
  let n = 0;
  for (const l of lines.filter(near)) {
    if (n + l.length > 4000) break;
    out.push(l);
    n += l.length;
  }
  return out.length
    ? [
        {
          type: "Feature",
          properties: { side, from },
          geometry: { type: "MultiLineString", coordinates: out },
        },
      ]
    : [];
}

/** Which street wasn't found, or how close the two come: in words. */
function explain(
  sides: [CrossingSide, CrossingSide],
  hits: CrossingHit[],
  nearest: CrossingLookup["nearest"],
): string | null {
  if (hits.length) return null;
  const q = (s: CrossingSide) => `“${s.typed}”`;
  const where = (s: CrossingSide) =>
    s.osmTried
      ? "in the wiki's streets or on OpenStreetMap"
      : "in the wiki's streets";
  const missing = sides.filter((s) => !s.found);
  if (missing.length === 2)
    return `Couldn't find either street, ${q(sides[0])} or ${q(sides[1])}, ${where(sides[0])}.`;
  if (missing.length === 1) {
    const m = missing[0];
    const other = sides.find((s) => s !== m)!;
    const unshaped = m.pages.length && !m.pages.some((p) => p.shapes > 0);
    const said = unshaped
      ? `${q(m)} has a page (${m.pages[0].name}) but no shape on the map to cross${m.osmTried ? ", and isn't on OpenStreetMap" : ""}.`
      : `Couldn't find ${q(m)} ${where(m)}.`;
    return `${said} ${other.osm ?? other.pages[0]?.name ?? other.typed} was found: it's drawn on the map.`;
  }
  return `Found both streets, but they don't meet${nearest ? `: the closest they come is ${Math.round(nearest.gap_m)} m apart` : ""}. Both are drawn on the map.`;
}

/**
 * Where two streets cross, for pinning a scan to a street corner: the wiki's own streets first (any
 * name they had, in the sheet's year), then today's streets from OpenStreetMap for the ones that
 * aren't mapped here (or are, but don't meet). It says which street it couldn't find, offers the
 * wiki's streets with names like it, draws what it found, and gives the closest point when the two
 * don't meet. Signed-in editors only (the fallback goes out to Nominatim).
 * ?q=Broadway %26 5th Ave &at=1925 &near=lon,lat &osm=1 (look on today's map even if the wiki found it)
 */
export const GET: RequestHandler = async ({ url, locals }) => {
  const { user } = await locals.safeGetSession();
  if (!user) error(401, "Sign in to look up street corners");
  const q = (url.searchParams.get("q") ?? "").trim().slice(0, 200);
  const pair = splitCrossing(q);
  const empty: GeoJSON.FeatureCollection = {
    type: "FeatureCollection",
    features: [],
  };
  if (!pair)
    return json({
      hits: [],
      streets: null,
      sides: null,
      nearest: null,
      lines: empty,
      problem: "Type two streets, like “Broadway & 5th Ave”.",
    } satisfies CrossingLookup);
  const at = /^\d{4}$/.test(url.searchParams.get("at") ?? "")
    ? `${url.searchParams.get("at")}-07-01`
    : null;
  const n = (url.searchParams.get("near") ?? "").split(",").map(Number);
  const near =
    n.length === 2 && n.every(Number.isFinite) ? ([n[0], n[1]] as LL) : null;

  const { data, error: err } = await locals.supabase.rpc("street_lookup", {
    p_a: pair[0],
    p_b: pair[1],
    p_at: at,
    p_near: near ? { lon: near[0], lat: near[1] } : null,
  });
  if (err) error(500, err.message);
  const w = data as Wiki;
  const wikiHits: CrossingHit[] = (w.hits ?? []).map((r) => ({
    lon: Number(r.lon),
    lat: Number(r.lat),
    a: r.a.name,
    b: r.b.name,
    a_slug: r.a.slug,
    b_slug: r.b.slug,
    gap_m: Number(r.gap_m),
    from: "wiki",
    then: r.then,
  }));
  const side = (
    typed: string,
    pages: Page[],
    suggest: string[],
  ): CrossingSide => ({
    typed,
    pages: pages.map((p) => ({
      slug: p.slug,
      name: p.name,
      shapes: Number(p.shapes),
    })),
    osmTried: false,
    osm: null,
    found: pages.some((p) => Number(p.shapes) > 0),
    suggest: suggest ?? [],
  });
  const sides: [CrossingSide, CrossingSide] = [
    side(pair[0], w.a?.pages ?? [], w.suggest?.a),
    side(pair[1], w.b?.pages ?? [], w.suggest?.b),
  ];
  const wl = { a: linesOf(w.lines?.a), b: linesOf(w.lines?.b) };
  const answer = (
    hits: CrossingHit[],
    nearest: CrossingLookup["nearest"],
    osm: { a: LL[][]; b: LL[][] } = { a: [], b: [] },
  ) => {
    const spot: LL | null = hits[0]
      ? [hits[0].lon, hits[0].lat]
      : nearest
        ? [nearest.lon, nearest.lat]
        : near;
    const lines: GeoJSON.FeatureCollection = {
      type: "FeatureCollection",
      features: [
        ...drawable(wl.a, spot, "a", "wiki"),
        ...drawable(wl.b, spot, "b", "wiki"),
        ...drawable(osm.a, spot, "a", "osm"),
        ...drawable(osm.b, spot, "b", "osm"),
      ],
    };
    return json({
      hits,
      streets: pair,
      sides,
      nearest,
      lines,
      problem: explain(sides, hits, nearest),
    } satisfies CrossingLookup);
  };
  if (wikiHits.length && url.searchParams.get("osm") !== "1")
    return answer(wikiHits, null);

  // today's map: a street the wiki has a shape of (and the other not) is crossed with today's
  // other street first, so a street that's gone still works; then both from OpenStreetMap
  const settings = await loadSettings(locals.supabase);
  const one = wl.a.length > 0 !== wl.b.length > 0;
  let osm = one
    ? await osmLookup(
        pair[0],
        pair[1],
        settings,
        url.origin,
        near,
        wl.a.length ? { a: wl.a } : { b: wl.b },
      )
    : null;
  let mixed = !!osm?.hits.length;
  if (!osm?.hits.length) {
    const pure = await osmLookup(pair[0], pair[1], settings, url.origin, near);
    if (pure.hits.length || !osm || pure.a.found || pure.b.found) osm = pure;
    mixed = false;
  }
  const known = mixed ? (wl.a.length ? "a" : "b") : null;
  for (const [i, s] of (["a", "b"] as const).entries()) {
    if (known === s) continue;
    sides[i].osmTried = true;
    sides[i].osm = osm![s].found ? (osm![s].name ?? sides[i].typed) : null;
    sides[i].found ||= osm![s].found;
  }
  const hits = [
    ...wikiHits,
    ...osm!.hits.map(
      (h): CrossingHit => ({ ...h, from: mixed ? "mixed" : "osm" }),
    ),
  ];
  const near2 = [
    w.nearest ? { ...w.nearest, from: "wiki" as const } : null,
    osm!.nearest ? { ...osm!.nearest, from: "osm" as const } : null,
  ]
    .filter((x): x is NonNullable<typeof x> => !!x)
    .sort((x, y) => x.gap_m - y.gap_m)[0];
  return answer(hits, hits.length ? null : (near2 ?? null), {
    a: known === "a" ? [] : osm!.a.lines,
    b: known === "b" ? [] : osm!.b.lines,
  });
};
