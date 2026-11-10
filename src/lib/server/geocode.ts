import { env } from '$env/dynamic/private';
import { closestApproach, crossings, linesOf, type LL } from '$lib/map/crossings';
import type { GeoAddressHit, SiteSettings } from '$lib/types';

/**
 * Address lookup through OpenStreetMap Nominatim, used by search to offer
 * addresses that are not in the wiki yet. This is server-side and throttled to
 * Nominatim's one-request-per-second policy, with a short-lived cache.
 *
 * https://operations.osmfoundation.org/policies/nominatim/
 */

// NOMINATIM_URL: another Nominatim (your own, or a stand-in for tests)
const ENDPOINT = env.NOMINATIM_URL || 'https://nominatim.openstreetmap.org/search';
const TTL_MS = 10 * 60 * 1000;
const cache = new Map<string, { at: number; hits: GeoAddressHit[] }>();
let lastRequest = 0;
let queue = Promise.resolve();

type NominatimAddress = {
	house_number?: string;
	road?: string;
	pedestrian?: string;
	footway?: string;
	cycleway?: string;
	path?: string;
	city?: string;
	town?: string;
	village?: string;
	hamlet?: string;
	municipality?: string;
	county?: string;
	postcode?: string;
	state?: string;
};

type NominatimHit = {
	place_id: number;
	display_name: string;
	lat: string;
	lon: string;
	address?: NominatimAddress;
	category?: string;
	name?: string;
	geojson?: GeoJSON.Geometry;
};

function streetOf(a: NominatimAddress | undefined): string | null {
	return a?.road ?? a?.pedestrian ?? a?.footway ?? a?.cycleway ?? a?.path ?? null;
}

function localityOf(a: NominatimAddress | undefined): string | null {
	return a?.city ?? a?.town ?? a?.village ?? a?.hamlet ?? a?.municipality ?? a?.county ?? null;
}

function shortLabel(houseNumber: string | null, street: string | null, settings: SiteSettings): string {
	if (!street) return houseNumber ?? '';
	if (!houseNumber) return street;
	return settings.address_format === 'street_number' ? `${street} ${houseNumber}` : `${houseNumber} ${street}`;
}

/** Bias results toward the site, clamped to Nominatim's 0.25° viewbox limit. */
function viewbox(settings: SiteSettings): string {
	const b = settings.map_bounds;
	const cx = b ? (b[0] + b[2]) / 2 : settings.map_center_lon;
	const cy = b ? (b[1] + b[3]) / 2 : settings.map_center_lat;
	const dx = Math.min(b ? Math.abs(b[2] - b[0]) / 2 : 0.12, 0.12);
	const dy = Math.min(b ? Math.abs(b[3] - b[1]) / 2 : 0.12, 0.12);
	return `${cx - dx},${cy + dy},${cx + dx},${cy - dy}`;
}

const agent = (settings: SiteSettings, origin: string) => `${settings.site_name || 'Decaynet'} address search (${origin})`;

async function throttle() {
	queue = queue.then(async () => {
		const wait = 1000 - (Date.now() - lastRequest);
		if (wait > 0) await new Promise((r) => setTimeout(r, wait));
		lastRequest = Date.now();
	});
	return queue;
}

export async function geocodeAddresses(q: string, settings: SiteSettings, origin: string): Promise<GeoAddressHit[]> {
	const key = `${q.toLowerCase()}|${settings.map_center_lon},${settings.map_center_lat}`;
	const cached = cache.get(key);
	if (cached && Date.now() - cached.at < TTL_MS) return cached.hits;
	cache.delete(key);

	const params = new URLSearchParams({
		q,
		format: 'jsonv2',
		addressdetails: '1',
		limit: '8',
		bounded: '0',
		viewbox: viewbox(settings)
	});

	await throttle();
	let hits: GeoAddressHit[] = [];
	try {
		const res = await fetch(`${ENDPOINT}?${params}`, {
			headers: {
				'User-Agent': agent(settings, origin),
				'Accept-Language': settings.content_language || 'en'
			},
			signal: AbortSignal.timeout(5000)
		});
		if (res.ok) {
			const rows = (await res.json()) as NominatimHit[];
			hits = rows
				.map((r): GeoAddressHit | null => {
					const houseNumber = r.address?.house_number ?? null;
					const street = streetOf(r.address);
					const lat = Number(r.lat);
					const lon = Number(r.lon);
					if (!houseNumber || !street || !Number.isFinite(lat) || !Number.isFinite(lon)) return null;
					return {
						place_id: r.place_id,
						label: shortLabel(houseNumber, street, settings),
						display_name: r.display_name,
						lat,
						lon,
						house_number: houseNumber,
						street,
						locality: localityOf(r.address)
					} satisfies GeoAddressHit;
				})
				.filter((h): h is GeoAddressHit => h !== null)
				.slice(0, 5);
		}
	} catch {
		// Offline or rate limited: the wiki's own addresses still work.
	}

	cache.set(key, { at: Date.now(), hits });
	if (cache.size > 200) cache.delete(cache.keys().next().value!);
	return hits;
}

// ---------------------------------------------------------------- street crossings
// For the workbench's "pin an intersection" when a street isn't mapped in the wiki: today's
// streets from OpenStreetMap (each street's ways, as lines), and where they cross. Two requests,
// one per street, each a second apart; cached like addresses.

const streetCache = new Map<string, { at: number; lines: LL[][]; name: string | null; ways: number }>();
const ORDINALS = ['first', 'second', 'third', 'fourth', 'fifth', 'sixth', 'seventh', 'eighth', 'ninth', 'tenth',
	'eleventh', 'twelfth', 'thirteenth', 'fourteenth', 'fifteenth', 'sixteenth', 'seventeenth', 'eighteenth', 'nineteenth', 'twentieth'];
const SUFFIX = (n: number) => `${n}${n % 10 === 1 && n !== 11 ? 'st' : n % 10 === 2 && n !== 12 ? 'nd' : n % 10 === 3 && n !== 13 ? 'rd' : 'th'}`;
const LONG: Record<string, string> = {
	ave: 'Avenue', av: 'Avenue', st: 'Street', blvd: 'Boulevard', rd: 'Road', dr: 'Drive', pl: 'Place', ct: 'Court',
	ln: 'Lane', hwy: 'Highway', pkwy: 'Parkway', ter: 'Terrace', n: 'North', s: 'South', e: 'East', w: 'West'
};

/** "N. Fifth Ave" → "North 5th Avenue": how OpenStreetMap spells streets. */
export function osmSpelling(name: string): string {
	return name
		.replace(/\./g, ' ')
		.split(/\s+/)
		.filter(Boolean)
		.map((w, i, all) => {
			const k = ORDINALS.indexOf(w.toLowerCase());
			if (k >= 0) return SUFFIX(k + 1);
			const l = LONG[w.toLowerCase()];
			// "St" first is Saint, not Street; a direction only at either end
			if (l && !(w.toLowerCase() === 'st' && i === 0 && all.length > 1)) return l;
			return w;
		})
		.join(' ');
}

/** A street's ways in a box (the site's, or where the other street runs): at most 40 of them. */
type OsmStreet = { lines: LL[][]; name: string | null; /** ways found: 40 means the search was cut off */ ways: number };

/** A street's ways in a box (the site's, the view's, or round a corner): at most 40 of them. */
async function osmStreet(name: string, settings: SiteSettings, origin: string, box: string = viewbox(settings)): Promise<OsmStreet> {
	const key = `${name.toLowerCase()}|${box}`;
	const cached = streetCache.get(key);
	if (cached && Date.now() - cached.at < TTL_MS) return cached;
	let out: OsmStreet = { lines: [], name: null, ways: 0 };
	for (const q of [...new Set([name, osmSpelling(name)])]) {
		const params = new URLSearchParams({
			q,
			format: 'jsonv2',
			polygon_geojson: '1',
			dedupe: '0',
			limit: '40',
			bounded: '1',
			viewbox: box
		});
		await throttle();
		try {
			const res = await fetch(`${ENDPOINT}?${params}`, {
				headers: { 'User-Agent': agent(settings, origin), 'Accept-Language': settings.content_language || 'en' },
				signal: AbortSignal.timeout(6000)
			});
			if (!res.ok) break;
			const rows = (await res.json()) as NominatimHit[];
			const ways = rows.filter((r) => r.category === 'highway' && r.geojson);
			out = { lines: ways.flatMap((r) => linesOf(r.geojson)), name: ways[0]?.name ?? null, ways: rows.length };
		} catch {
			break; // offline or rate limited
		}
		if (out.lines.length) break;
	}
	streetCache.set(key, { at: Date.now(), ...out });
	if (streetCache.size > 200) streetCache.delete(streetCache.keys().next().value!);
	return out;
}

/** The box round some lines, ~300 m wider each way, as a Nominatim viewbox. */
function boxAround(lines: LL[][]): string {
	const pts = lines.flat();
	const pad = 0.003;
	const xs = pts.map((p) => p[0]);
	const ys = pts.map((p) => p[1]);
	return `${Math.min(...xs) - pad},${Math.max(...ys) + pad},${Math.max(...xs) + pad},${Math.min(...ys) - pad}`;
}

export type OsmCrossing = { lon: number; lat: number; gap_m: number; a: string; b: string };
export type OsmSide = {
	/** found on OpenStreetMap (or given: the wiki's own shape of it) */
	found: boolean;
	/** as OpenStreetMap names it */
	name: string | null;
	lines: LL[][];
};
export type OsmLookup = { hits: OsmCrossing[]; a: OsmSide; b: OsmSide; nearest: { lon: number; lat: number; gap_m: number } | null };

/** A Nominatim viewbox d degrees each way round a point. */
const boxAt = ([x, y]: LL, d: number) => `${x - d},${y + d},${x + d},${y - d}`;

/**
 * Where two of today's streets cross, from OpenStreetMap, nearest `near` first; and, when they
 * don't, which street wasn't found or how close they come. A search returns at most 40 ways and
 * a long street has more, so the piece at the corner can be missing: it looks first round the
 * view (~2 km), then across the site; and where the streets come closest without meeting, it
 * looks again right there. `known` lines stand in for a street the wiki has a shape of (so a
 * street that's gone can still be crossed with one of today's). A few requests, a second apart.
 */
export async function osmLookup(
	a: string,
	b: string,
	settings: SiteSettings,
	origin: string,
	near: LL | null,
	known: { a?: LL[][]; b?: LL[][] } = {}
): Promise<OsmLookup> {
	const A: OsmSide = { found: !!known.a?.length, name: null, lines: known.a ?? [] };
	const B: OsmSide = { found: !!known.b?.length, name: null, lines: known.b ?? [] };
	const add = (side: OsmSide, got: OsmStreet) => {
		if (!got.lines.length) return;
		side.found = true;
		side.name ??= got.name;
		side.lines = [...side.lines, ...got.lines];
	};
	const done = (hits: OsmCrossing[], nearest: OsmLookup['nearest'] = null): OsmLookup => ({ hits, a: A, b: B, nearest });
	const named = (h: ReturnType<typeof crossings>) => h.slice(0, 6).map((c) => ({ ...c, a: A.name ?? a, b: B.name ?? b }));
	const boxes = [near ? boxAt(near, 0.02) : null, viewbox(settings)].filter((x): x is string => !!x);
	for (const [round, box] of boxes.entries()) {
		const last = round === boxes.length - 1;
		// a known street's lines say where to look for the other
		if (!known.a?.length) add(A, await osmStreet(a, settings, origin, known.b?.length ? boxAround(known.b) : box));
		if (!known.b?.length) add(B, await osmStreet(b, settings, origin, known.a?.length ? boxAround(known.a) : box));
		if (!A.found || !B.found) {
			// a known street with the other not near it: no wider search will help
			if (known.a?.length || known.b?.length) break;
			continue;
		}
		let hits = crossings(A.lines, B.lines, near);
		if (hits.length) return done(named(hits));
		// both found, not meeting in what came back: look again where they'd meet
		const c = closestApproach(A.lines, B.lines);
		if (c && c.gap_m < 5000) {
			const there = boxAt(c.meet, 0.006);
			if (!known.a?.length) add(A, await osmStreet(a, settings, origin, there));
			if (!known.b?.length) add(B, await osmStreet(b, settings, origin, there));
			hits = crossings(A.lines, B.lines, near);
			if (hits.length) return done(named(hits));
		}
		// searched everywhere they could be: they don't meet
		if (last || known.a?.length || known.b?.length) {
			const n = closestApproach(A.lines, B.lines);
			return done([], n && n.gap_m <= 2000 ? { lon: n.lon, lat: n.lat, gap_m: n.gap_m } : null);
		}
	}
	return done([]);
}
