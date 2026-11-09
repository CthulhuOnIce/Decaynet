import { env } from '$env/dynamic/private';
import { crossings, linesOf, type LL } from '$lib/map/crossings';
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

const streetCache = new Map<string, { at: number; lines: LL[][]; name: string | null }>();
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
async function osmStreet(name: string, settings: SiteSettings, origin: string, box: string = viewbox(settings)): Promise<{ lines: LL[][]; name: string | null }> {
	const key = `${name.toLowerCase()}|${box}`;
	const cached = streetCache.get(key);
	if (cached && Date.now() - cached.at < TTL_MS) return cached;
	let out: { lines: LL[][]; name: string | null } = { lines: [], name: null };
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
			out = { lines: ways.flatMap((r) => linesOf(r.geojson)), name: ways[0]?.name ?? null };
		} catch {
			break; // offline or rate limited
		}
		if (out.lines.length) break;
	}
	streetCache.set(key, { at: Date.now(), ...out });
	if (streetCache.size > 200) streetCache.delete(streetCache.keys().next().value!);
	return out;
}

export type OsmCrossing = { lon: number; lat: number; gap_m: number; a: string; b: string };

/** The box round some lines, ~300 m wider each way, as a Nominatim viewbox. */
function boxAround(lines: LL[][]): string {
	const pts = lines.flat();
	const pad = 0.003;
	const xs = pts.map((p) => p[0]);
	const ys = pts.map((p) => p[1]);
	return `${Math.min(...xs) - pad},${Math.max(...ys) + pad},${Math.max(...xs) + pad},${Math.min(...ys) - pad}`;
}

/**
 * Where two of today's streets cross, from OpenStreetMap: nearest `near` first. A long street is
 * many ways, more than one search returns, so the second street is looked for only where the first
 * runs, and (if they still don't meet) the first again where the second runs. A few requests, a second apart.
 */
export async function osmCrossings(a: string, b: string, settings: SiteSettings, origin: string, near: LL | null): Promise<OsmCrossing[]> {
	const sa = await osmStreet(a, settings, origin);
	if (!sa.lines.length) return [];
	const sb = await osmStreet(b, settings, origin, boxAround(sa.lines));
	if (!sb.lines.length) return [];
	let hits = crossings(sa.lines, sb.lines, near);
	let names = { a: sa.name ?? a, b: sb.name ?? b };
	if (!hits.length) {
		const sa2 = await osmStreet(a, settings, origin, boxAround(sb.lines));
		hits = crossings(sa2.lines, sb.lines, near);
		names = { a: sa2.name ?? names.a, b: names.b };
	}
	return hits.slice(0, 6).map((c) => ({ ...c, ...names }));
}
