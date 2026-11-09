import { error, json } from "@sveltejs/kit";
import { loadSettings } from "$lib/server/db";
import { osmCrossings } from "$lib/server/geocode";
import { splitCrossing, type CrossingHit } from "$lib/map/crossings";
import type { RequestHandler } from "./$types";

/**
 * Where two streets cross, for pinning a scan to an intersection: the wiki's own streets first (any
 * name they had, in the sheet's year), then today's streets from OpenStreetMap for the ones that
 * aren't mapped here. Signed-in editors only (the fallback goes out to Nominatim).
 * ?q=Broadway %26 5th Ave &at=1925 &near=lon,lat
 */
export const GET: RequestHandler = async ({ url, locals }) => {
  const { user } = await locals.safeGetSession();
  if (!user) error(401, "Sign in to look up intersections");
  const q = (url.searchParams.get("q") ?? "").trim().slice(0, 200);
  const pair = splitCrossing(q);
  if (!pair)
    return json({
      hits: [],
      problem: "Type two streets, like “Broadway & 5th Ave”.",
    });
  const at = /^\d{4}$/.test(url.searchParams.get("at") ?? "")
    ? `${url.searchParams.get("at")}-07-01`
    : null;
  const n = (url.searchParams.get("near") ?? "").split(",").map(Number);
  const near =
    n.length === 2 && n.every(Number.isFinite)
      ? ([n[0], n[1]] as [number, number])
      : null;

  const { data, error: err } = await locals.supabase.rpc("street_crossings", {
    p_a: pair[0],
    p_b: pair[1],
    p_at: at,
    p_near: near ? { lon: near[0], lat: near[1] } : null,
  });
  if (err) error(500, err.message);
  type Row = {
    lon: number;
    lat: number;
    a: { slug: string; name: string };
    b: { slug: string; name: string };
    gap_m: number;
    then: boolean;
  };
  const wiki: CrossingHit[] = ((data ?? []) as Row[]).map((r) => ({
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
  if (wiki.length && url.searchParams.get("osm") !== "1")
    return json({ hits: wiki, streets: pair });

  // not mapped here (or asked for today's map as well): OpenStreetMap
  const settings = await loadSettings(locals.supabase);
  const osm = await osmCrossings(pair[0], pair[1], settings, url.origin, near);
  const hits = [
    ...wiki,
    ...osm.map((c): CrossingHit => ({ ...c, from: "osm" })),
  ];
  return json({
    hits,
    streets: pair,
    problem: hits.length
      ? null
      : `Couldn’t find where ${pair[0]} meets ${pair[1]}, in the wiki’s streets or on OpenStreetMap.`,
  });
};
