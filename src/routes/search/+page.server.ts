import { redirect } from '@sveltejs/kit';
import { looksLikeAddress } from '$lib/address';
import { loadSettings } from '$lib/server/db';
import { geocodeAddresses } from '$lib/server/geocode';
import type { AddressHit, GeoAddressHit, SearchHit } from '$lib/types';
import type { PageServerLoad } from './$types';

function nearby(a: { lon: number; lat: number }, b: { lon: number; lat: number }) {
	return Math.abs(a.lon - b.lon) < 0.0005 && Math.abs(a.lat - b.lat) < 0.0005;
}

export const load: PageServerLoad = async ({ url, locals }) => {
	const q = (url.searchParams.get('q') ?? '').trim();
	if (!q) return { q, hits: [] as SearchHit[], addresses: [] as AddressHit[], external: [] as GeoAddressHit[] };
	const [{ data: entityData }, { data: addressData }] = await Promise.all([
		locals.supabase.rpc('search_entities', { p_q: q, p_limit: 50 }),
		// Tolerate an older database that has not run the address-search migration yet.
		locals.supabase.rpc('search_addresses', { p_q: q, p_limit: 30 })
	]);
	const hits = (entityData ?? []) as SearchHit[];
	const addresses = (addressData ?? []) as AddressHit[];

	// Where the address is today, from OpenStreetMap, when the query looks like a street address.
	// Always kept (it's how you cross-reference a historic address with today's map), whatever the
	// wiki also found; ones the wiki already has are marked so they don't offer "create a page".
	let external: GeoAddressHit[] = [];
	if (looksLikeAddress(q)) {
		const settings = await loadSettings(locals.supabase);
		const found = await geocodeAddresses(q, settings, url.origin);
		external = found.map((e) => ({
			...e,
			known:
				addresses.some((a) => a.lon !== null && a.lat !== null && nearby({ lon: a.lon, lat: a.lat }, e)) ||
				addresses.some((a) => a.formatted.toLowerCase() === e.label.toLowerCase())
		}));
	}

	// Exact title hit and nothing else close: go straight there, like a wiki
	if (url.searchParams.get('go') !== '0' && hits.length === 1 && hits[0].name.toLowerCase() === q.toLowerCase())
		redirect(303, `/e/${hits[0].slug}`);
	return { q, hits, addresses, external };
};
