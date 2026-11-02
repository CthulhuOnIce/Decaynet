import type { GeoAddressHit, SiteSettings } from '$lib/types';

/**
 * Address lookup through OpenStreetMap Nominatim, used by search to offer
 * addresses that are not in the wiki yet. This is server-side and throttled to
 * Nominatim's one-request-per-second policy, with a short-lived cache.
 *
 * https://operations.osmfoundation.org/policies/nominatim/
 */

const ENDPOINT = 'https://nominatim.openstreetmap.org/search';
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
				'User-Agent': `${settings.site_name || 'Decaynet'} address search (${origin})`,
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
