import type { Candidate, ImportOptions } from '$lib/importTypes';
import { fetchOverpass, normalizeOhm, OSM_OVERPASS, type OverpassElement } from './ohm';

/**
 * Current OpenStreetMap: businesses and places that (probably) still exist.
 * No dates are guessed; the pages simply have no end, so they read as extant.
 */
export function buildOsmQuery(o: ImportOptions['osm'], bbox: ImportOptions['bbox']): string {
	const [w, s, e, n] = bbox;
	const b = `(${s},${w},${n},${e})`;
	const parts: string[] = [];
	if (o.businesses)
		parts.push(`node["shop"]["name"]${b};`, `node["amenity"]["name"]${b};`, `node["tourism"]["name"]${b};`, `node["office"]["name"]${b};`, `node["craft"]["name"]${b};`);
	if (o.places)
		parts.push(
			`nwr["historic"]["name"]${b};`,
			`nwr["leisure"]["name"]${b};`,
			`nwr["place"~"^(neighbourhood|suburb|quarter)$"]["name"]${b};`,
			`nwr["amenity"~"^(grave_yard|school|college|university|hospital|place_of_worship|theatre|cinema|library|townhall|courthouse)$"]["name"]${b};`,
			`nwr["tourism"~"^(attraction|museum|gallery|hotel|motel)$"]["name"]${b};`
		);
	if (o.buildings) parts.push(`nwr["building"]["name"]${b};`);
	return `[out:json][timeout:90][maxsize:268435456];(${parts.join('')});out tags geom 6000;`;
}

export const fetchOsm = (o: ImportOptions['osm'], bbox: ImportOptions['bbox'], userAgent: string) =>
	fetchOverpass(OSM_OVERPASS, 'OpenStreetMap', buildOsmQuery(o, bbox), userAgent);

export function normalizeOsm(elements: OverpassElement[], lang: string, heightUnit: string | null): Candidate[] {
	// only named things: an unnamed OSM node is rarely a useful page
	return normalizeOhm(elements, lang, heightUnit, 'osm').filter((c) => !c.unnamed);
}
