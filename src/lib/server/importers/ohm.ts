import type { Candidate, ImportOptions } from '$lib/importTypes';
import { parseOsmDate } from './dates';

/** OpenHistoricalMap's public Overpass endpoint (same API as OSM's Overpass). */
export const OHM_OVERPASS = 'https://overpass-api.openhistoricalmap.org/api/interpreter';

interface OverpassElement {
	type: 'node' | 'way' | 'relation';
	id: number;
	lat?: number;
	lon?: number;
	tags?: Record<string, string>;
	geometry?: { lat: number; lon: number }[];
	members?: { type: string; role: string; geometry?: { lat: number; lon: number }[] }[];
}

export function buildOverpassQuery(o: ImportOptions['ohm'], bbox: ImportOptions['bbox']): string {
	const [w, s, e, n] = bbox;
	const b = `(${s},${w},${n},${e})`;
	const parts: string[] = [];
	if (o.buildings) parts.push(o.unnamedBuildings ? `nwr["building"]${b};` : `nwr["building"]["name"]${b};`);
	if (o.streets) parts.push(`way["highway"]["name"]${b};`);
	if (o.railways) parts.push(`way["railway"~"^(rail|tram|light_rail|subway|abandoned|disused|narrow_gauge)$"]${b};`, `nwr["railway"="station"]${b};`);
	if (o.water) parts.push(`nwr["natural"="water"]${b};`, `way["waterway"~"^(river|canal|stream|riverbank)$"]${b};`, `relation["waterway"]${b};`);
	if (o.businesses)
		parts.push(`node["shop"]${b};`, `node["amenity"]["name"]${b};`, `node["tourism"]["name"]${b};`, `node["office"]["name"]${b};`, `node["craft"]${b};`);
	if (o.places)
		parts.push(
			`nwr["place"~"^(neighbourhood|suburb|quarter|hamlet|village)$"]${b};`,
			`nwr["landuse"]["name"]${b};`,
			`nwr["leisure"]["name"]${b};`,
			`nwr["historic"]${b};`,
			`nwr["amenity"~"^(grave_yard|school|college|university|hospital|place_of_worship)$"]["name"]${b};`
		);
	return `[out:json][timeout:90][maxsize:268435456];(${parts.join('')});out tags geom 6000;`;
}

/** Pull a readable message out of an Overpass XML/HTML error page. */
function overpassError(body: string): string {
	const m = body.match(/<remark>([\s\S]*?)<\/remark>/) ?? body.match(/<p><strong[^>]*>Error<\/strong>:([\s\S]*?)<\/p>/);
	return (m?.[1] ?? body.replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim().slice(0, 240);
}

/**
 * Query OHM's Overpass. The public server allows only a couple of concurrent
 * queries per IP and answers overload with an XML error page, so retry a few
 * times with backoff before giving up.
 */
export async function fetchOhm(o: ImportOptions['ohm'], bbox: ImportOptions['bbox'], userAgent: string) {
	const body = new URLSearchParams({ data: buildOverpassQuery(o, bbox) });
	let last = '';
	for (const wait of [0, 3000, 8000, 15000]) {
		if (wait) await new Promise((r) => setTimeout(r, wait));
		const res = await fetch(OHM_OVERPASS, {
			method: 'POST',
			headers: { 'content-type': 'application/x-www-form-urlencoded', 'user-agent': userAgent, accept: 'application/json' },
			body,
			signal: AbortSignal.timeout(100_000)
		});
		const text = await res.text();
		if (res.ok && text.trimStart().startsWith('{')) {
			const json = JSON.parse(text) as { elements: OverpassElement[]; remark?: string };
			return { elements: json.elements ?? [], remark: json.remark ?? null };
		}
		last = `${res.status}: ${overpassError(text)}`;
		const retryable = res.status === 429 || res.status >= 500 || /rate|too many|timeout|try again|dispatcher|load/i.test(text);
		if (!retryable) break;
	}
	throw new Error(`OpenHistoricalMap Overpass is busy or refused the query (${last}). Try again in a minute.`);
}

// ----------------------------------------------------------------------------- geometry

const coords = (g: { lat: number; lon: number }[]) => g.map((p) => [+p.lon.toFixed(7), +p.lat.toFixed(7)]);
const closed = (c: number[][]) => c.length >= 4 && c[0][0] === c[c.length - 1][0] && c[0][1] === c[c.length - 1][1];

const AREA_KEYS = ['building', 'landuse', 'leisure', 'amenity', 'natural', 'place', 'historic', 'man_made', 'water', 'tourism', 'shop'];
const isArea = (t: Record<string, string>) =>
	t.area === 'yes' || (t.area !== 'no' && !t.highway && !t.railway && !t.waterway && AREA_KEYS.some((k) => k in t)) || t.waterway === 'riverbank';

/** Join open member ways end-to-end into closed rings (simple multipolygon assembly). */
function assembleRings(lines: number[][][]): number[][][] {
	const rings: number[][][] = [];
	const pool = lines.map((l) => [...l]);
	while (pool.length) {
		let ring = pool.shift()!;
		let guard = 0;
		while (!closed(ring) && guard++ < 500) {
			const end = ring[ring.length - 1];
			const i = pool.findIndex((l) => (l[0][0] === end[0] && l[0][1] === end[1]) || (l[l.length - 1][0] === end[0] && l[l.length - 1][1] === end[1]));
			if (i < 0) break;
			const next = pool.splice(i, 1)[0];
			ring = ring.concat((next[0][0] === end[0] && next[0][1] === end[1] ? next : next.reverse()).slice(1));
		}
		if (closed(ring)) rings.push(ring);
	}
	return rings;
}

function toGeometry(el: OverpassElement): GeoJSON.Geometry | null {
	const t = el.tags ?? {};
	if (el.type === 'node' && el.lat != null && el.lon != null) return { type: 'Point', coordinates: [+el.lon.toFixed(7), +el.lat.toFixed(7)] };
	if (el.type === 'way' && el.geometry?.length) {
		const c = coords(el.geometry);
		return closed(c) && isArea(t) ? { type: 'Polygon', coordinates: [c] } : { type: 'LineString', coordinates: c };
	}
	if (el.type === 'relation' && el.members?.length) {
		const ways = el.members.filter((m) => m.type === 'way' && m.geometry?.length);
		if (t.type === 'multipolygon' || t.type === 'boundary') {
			const outers = assembleRings(ways.filter((m) => m.role !== 'inner').map((m) => coords(m.geometry!)));
			const inners = assembleRings(ways.filter((m) => m.role === 'inner').map((m) => coords(m.geometry!)));
			if (!outers.length) return null;
			if (outers.length === 1) return { type: 'Polygon', coordinates: [outers[0], ...inners] };
			return { type: 'MultiPolygon', coordinates: outers.map((o) => [o]) };
		}
		const lines = ways.map((m) => coords(m.geometry!));
		return lines.length ? { type: 'MultiLineString', coordinates: lines } : null;
	}
	return null;
}

// ----------------------------------------------------------------------------- classification

const SKIP_AMENITY = new Set(['parking', 'parking_space', 'bench', 'waste_basket', 'bicycle_parking', 'vending_machine', 'post_box', 'telephone', 'toilets', 'drinking_water', 'parking_entrance', 'fountain', 'charging_station', 'atm', 'shelter']);

function classify(t: Record<string, string>, geomType: string | undefined): { kind: string; role: string } | null {
	const area = geomType === 'Polygon' || geomType === 'MultiPolygon';
	if (t.building) return { kind: 'building', role: area ? 'footprint' : 'point' };
	if (t.highway) {
		if (/^(motorway|motorway_link|trunk|trunk_link)$/.test(t.highway)) return { kind: 'infrastructure', role: 'centerline' };
		return { kind: 'street', role: 'centerline' };
	}
	if (t.railway === 'station') return { kind: 'site', role: area ? 'shape' : 'point' };
	if (t.railway) return { kind: 'infrastructure', role: 'centerline' };
	if (t.natural === 'water' || t.waterway || t.water) return { kind: 'water', role: area ? 'shape' : 'centerline' };
	if (t.place) return { kind: 'district', role: area ? 'boundary' : 'point' };
	if (t.amenity && SKIP_AMENITY.has(t.amenity)) return null;
	if ((t.shop || t.amenity || t.office || t.craft || t.tourism) && !area) return { kind: 'organization', role: 'point' };
	if (t.landuse === 'residential' && t.name) return { kind: 'district', role: 'boundary' };
	if (t.landuse || t.leisure || t.historic || t.amenity || t.tourism) return { kind: 'site', role: area ? 'shape' : 'point' };
	return null;
}

/** OSM tag → Decaynet tag slug (only applied if that tag exists on this site). */
function tagSlugs(t: Record<string, string>): string[] {
	const out = new Set<string>();
	const a = t.amenity;
	if (a && /^(restaurant|fast_food|cafe|food_court)$/.test(a)) out.add('restaurant');
	if (a && /^(bar|pub|biergarten)$/.test(a)) out.add('bar-tavern');
	if (a === 'cinema') out.add('movie-theater');
	if (a === 'theatre' || a === 'arts_centre') out.add('entertainment');
	if (a === 'nightclub') out.add('music-venue');
	if (a === 'place_of_worship' || t.building === 'church' || t.building === 'cathedral') out.add(t.religion === 'christian' || /church|cathedral/.test(t.building ?? '') ? 'church' : 'religious');
	if (a && /^(school|college|university|kindergarten)$/.test(a)) out.add('school');
	if (a && /^(townhall|courthouse|police|fire_station|post_office|library)$/.test(a)) out.add('civic');
	if (t.tourism === 'hotel' || t.tourism === 'motel' || t.building === 'hotel') out.add('hotel');
	if (t.shop) out.add(/^(supermarket|grocery|convenience|greengrocer|butcher|bakery)$/.test(t.shop) ? 'grocery' : t.shop === 'department_store' ? 'department-store' : 'retail');
	if (t.railway === 'station') out.add('rail-station');
	if (t.landuse === 'industrial' || t.man_made === 'works' || /^(industrial|warehouse|factory)$/.test(t.building ?? '')) out.add('industrial');
	return [...out];
}

function nameOf(t: Record<string, string>, lang: string): string | null {
	if (t.name) return t.name;
	if (t[`name:${lang}`]) return t[`name:${lang}`];
	if (t['name:en']) return t['name:en'];
	if (t['addr:housenumber'] && t['addr:street']) return `${t['addr:housenumber']} ${t['addr:street']}`;
	return null;
}

const SHOP_LABEL = (t: Record<string, string>) => {
	const v = t.shop ?? t.amenity ?? t.office ?? t.craft ?? t.tourism ?? t.building;
	return v && v !== 'yes' ? v.replace(/_/g, ' ') : null;
};

// ----------------------------------------------------------------------------- normalize

/** OSM heights are metres; store them in whatever unit this site's "height" attribute uses. */
const toHeightUnit = (metres: number, unit: string | null) =>
	/^(ft|feet|foot)$/i.test(unit ?? '') ? Math.round(metres * 3.28084) : Math.round(metres * 10) / 10;

export function normalizeOhm(elements: OverpassElement[], lang = 'en', heightUnit: string | null = 'm'): Candidate[] {
	const out: Candidate[] = [];
	for (const el of elements) {
		const t = el.tags ?? {};
		const geometry = toGeometry(el);
		const cls = classify(t, geometry?.type);
		if (!cls || !geometry) continue;
		const from = parseOsmDate(t['start_date:edtf'] ?? t.start_date);
		const to = parseOsmDate(t['end_date:edtf'] ?? t.end_date);
		const name = nameOf(t, lang);
		const label = SHOP_LABEL(t);
		const unnamed = !name;
		const fallback =
			cls.kind === 'organization'
				? `Unnamed ${label ?? 'business'}`
				: cls.kind === 'building'
					? `Unnamed ${label && label !== 'building' ? label + ' ' : ''}building`
					: `Unnamed ${cls.kind}`;
		const names: Candidate['names'] = [];
		const localized = t[`name:${lang}`];
		if (localized && name && localized !== name) names.push({ name: localized, name_type: 'alternate', source: 'ohm' });
		for (const [k, type] of [['old_name', 'historic'], ['alt_name', 'alternate'], ['official_name', 'official'], ['loc_name', 'common']] as const)
			for (const v of (t[k] ?? '').split(';').map((x) => x.trim()).filter(Boolean)) names.push({ name: v, name_type: type, source: 'ohm' });

		const attributes: Candidate['attributes'] = [];
		if (t['building:levels'] && Number.isFinite(+t['building:levels'])) attributes.push({ key: 'floors', value: +t['building:levels'], source: 'ohm' });
		if (t.architect) attributes.push({ key: 'architect', value: t.architect, source: 'ohm' });
		if (t.height && Number.isFinite(parseFloat(t.height))) attributes.push({ key: 'height', value: toHeightUnit(parseFloat(t.height), heightUnit), source: 'ohm' });
		if (t['building:material']) attributes.push({ key: 'material', value: t['building:material'], source: 'ohm' });
		if (t.ref && (cls.kind === 'infrastructure' || cls.kind === 'street')) attributes.push({ key: 'route_designation', value: t.ref, source: 'ohm' });
		if (t.website) attributes.push({ key: 'website', value: t.website, source: 'ohm' });
		if (cls.kind === 'organization' && label) attributes.push({ key: 'industry', value: label, source: 'ohm' });

		out.push({
			key: `ohm:${el.type}/${el.id}`,
			origin: 'ohm',
			kind: cls.kind,
			name: name ?? `${fallback} (OHM ${el.type[0]}${el.id})`,
			unnamed,
			summary: t.description ?? null,
			exists_from: from?.date ?? null,
			exists_from_precision: from?.precision ?? 'year',
			exists_to: to?.date ?? null,
			exists_to_precision: to?.precision ?? 'year',
			approximate: Boolean(from?.approximate || to?.approximate),
			geometry,
			geometry_source: 'ohm',
			fact_source: 'ohm',
			role: cls.role,
			names,
			attributes,
			tags: tagSlugs(t),
			ext: [{ source: 'ohm', id: `${el.type}/${el.id}`, url: `https://www.openhistoricalmap.org/${el.type}/${el.id}` }],
			wikidata: /^Q\d+$/.test(t.wikidata ?? '') ? t.wikidata : null,
			image_url: null,
			classes: [label ?? cls.kind],
			raw: t
		});
	}
	return groupLinear(out);
}

/**
 * OSM-style data splits one street into many ways. Merge same-named linear
 * features with the same dates into one page with a MultiLineString.
 */
function groupLinear(cands: Candidate[]): Candidate[] {
	const groups = new Map<string, Candidate>();
	const rest: Candidate[] = [];
	for (const c of cands) {
		const linear = c.geometry && /LineString/.test(c.geometry.type) && ['street', 'infrastructure', 'water'].includes(c.kind) && !c.unnamed;
		if (!linear) {
			rest.push(c);
			continue;
		}
		const k = `${c.kind}|${c.name.toLowerCase()}|${c.exists_from}|${c.exists_to}`;
		const g = groups.get(k);
		const lines = (geom: GeoJSON.Geometry) =>
			geom.type === 'LineString' ? [geom.coordinates] : geom.type === 'MultiLineString' ? geom.coordinates : [];
		if (!g) {
			groups.set(k, { ...c, key: `${c.key}+`, geometry: { type: 'MultiLineString', coordinates: lines(c.geometry!) } });
		} else {
			(g.geometry as GeoJSON.MultiLineString).coordinates.push(...lines(c.geometry!));
			g.ext.push(...c.ext);
			for (const n of c.names) if (!g.names.some((x) => x.name === n.name)) g.names.push(n);
			for (const a of c.attributes) if (!g.attributes.some((x) => x.key === a.key)) g.attributes.push(a);
			g.wikidata ??= c.wikidata;
		}
	}
	return [...rest, ...groups.values()];
}
