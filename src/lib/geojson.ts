/**
 * Read pasted GeoJSON into the one geometry the database stores.
 *
 * Accepts a bare geometry, a Feature, a FeatureCollection (what the workbench's
 * Copy and Download produce, and what most tools export) or a GeometryCollection.
 * Several shapes of one kind become one multi-part shape (a building's wings,
 * a street in segments). Height values are dropped, unclosed rings are closed,
 * and coordinates that aren't longitude/latitude are explained instead of
 * reaching PostGIS as "invalid GeoJSON representation".
 */

export type GeometryResult = { geometry: GeoJSON.Geometry; parts: number; note?: string } | { error: string };

type Pos = [number, number];
const SIMPLE = ['Point', 'LineString', 'Polygon'] as const;
type Simple = (typeof SIMPLE)[number];
const MULTI: Record<Simple, 'MultiPoint' | 'MultiLineString' | 'MultiPolygon'> = {
	Point: 'MultiPoint',
	LineString: 'MultiLineString',
	Polygon: 'MultiPolygon'
};
const NOUN: Record<Simple, string> = { Point: 'point', LineString: 'line', Polygon: 'area' };

class Bad extends Error {}

function pos(c: unknown): Pos {
	if (!Array.isArray(c) || c.length < 2 || typeof c[0] !== 'number' || typeof c[1] !== 'number' || !Number.isFinite(c[0]) || !Number.isFinite(c[1]))
		throw new Bad('Some coordinates are not pairs of numbers.');
	const [x, y] = c as number[];
	if (Math.abs(x) > 180 || Math.abs(y) > 90)
		throw new Bad(
			Math.abs(x) <= 90 && Math.abs(y) <= 180
				? 'The coordinates look like latitude, longitude. GeoJSON wants longitude first ([-87.33, 41.60]).'
				: 'The coordinates are not longitude/latitude (they look projected, e.g. State Plane or Web Mercator). Export as WGS 84 / EPSG:4326.'
		);
	return [x, y];
}
const line = (c: unknown, min: number): Pos[] => {
	if (!Array.isArray(c)) throw new Bad('A line or ring is not a list of coordinates.');
	const out = c.map(pos);
	if (out.length < min) throw new Bad(min === 2 ? 'A line needs at least two points.' : 'An area needs at least three corners.');
	return out;
};
const ring = (c: unknown): Pos[] => {
	const r = line(c, 3);
	const [a, b] = [r[0], r[r.length - 1]];
	if (a[0] !== b[0] || a[1] !== b[1]) r.push([a[0], a[1]]); // close it
	if (r.length < 4) throw new Bad('An area needs at least three corners.');
	return r;
};
const polygon = (c: unknown): Pos[][] => {
	if (!Array.isArray(c) || !c.length) throw new Bad('An area has no outline.');
	return c.map(ring);
};

/** Flatten anything into simple shapes (multi-part shapes split into their parts). */
function simples(g: unknown, out: { type: Simple; coordinates: unknown }[]) {
	if (!g || typeof g !== 'object') throw new Bad('That isn’t a GeoJSON shape.');
	const o = g as { type?: string; coordinates?: unknown; geometry?: unknown; features?: unknown[]; geometries?: unknown[] };
	switch (o.type) {
		case 'FeatureCollection':
			for (const f of o.features ?? []) simples(f, out);
			return;
		case 'Feature':
			if (o.geometry == null) return; // a feature with no shape
			return simples(o.geometry, out);
		case 'GeometryCollection':
			for (const x of o.geometries ?? []) simples(x, out);
			return;
		case 'Point':
			return void out.push({ type: 'Point', coordinates: pos(o.coordinates) });
		case 'LineString':
			return void out.push({ type: 'LineString', coordinates: line(o.coordinates, 2) });
		case 'Polygon':
			return void out.push({ type: 'Polygon', coordinates: polygon(o.coordinates) });
		case 'MultiPoint':
		case 'MultiLineString':
		case 'MultiPolygon': {
			const t = o.type.slice(5) as Simple;
			if (!Array.isArray(o.coordinates)) throw new Bad(`The ${o.type} has no coordinates.`);
			for (const c of o.coordinates) simples({ type: t, coordinates: c }, out);
			return;
		}
		default:
			throw new Bad(o.type ? `“${o.type}” isn’t a GeoJSON shape type.` : 'That isn’t GeoJSON: there is no "type".');
	}
}

/** Parse pasted text (or an already-parsed object) into one storable geometry. */
export function readGeometry(input: string | unknown): GeometryResult {
	let obj = input;
	if (typeof input === 'string') {
		const t = input.trim();
		if (!t) return { error: 'Nothing was pasted.' };
		try {
			obj = JSON.parse(t);
		} catch {
			return { error: 'That isn’t valid JSON. Paste the whole GeoJSON, including the outer { }.' };
		}
	}
	const parts: { type: Simple; coordinates: unknown }[] = [];
	try {
		simples(obj, parts);
	} catch (e) {
		if (e instanceof Bad) return { error: e.message };
		throw e;
	}
	if (!parts.length) return { error: 'The GeoJSON has no shapes in it.' };
	const kinds = [...new Set(parts.map((p) => p.type))];
	if (kinds.length > 1) {
		const list = kinds.map((k) => `${parts.filter((p) => p.type === k).length} ${NOUN[k]}${parts.filter((p) => p.type === k).length === 1 ? '' : 's'}`);
		return { error: `It mixes kinds of shape (${list.join(', ')}). Paste them one kind at a time.` };
	}
	const kind = kinds[0];
	if (parts.length === 1) return { geometry: parts[0] as GeoJSON.Geometry, parts: 1 };
	return {
		geometry: { type: MULTI[kind], coordinates: parts.map((p) => p.coordinates) } as GeoJSON.Geometry,
		parts: parts.length,
		note: `${parts.length} ${NOUN[kind]}s, saved together as one shape.`
	};
}
