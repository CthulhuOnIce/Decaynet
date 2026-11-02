import type { SupabaseClient } from '@supabase/supabase-js';
import type { Candidate, ImportOptions, ImportSource, MatchInfo, PlanItem, PreviewResult } from '$lib/importTypes';
import { formatFuzzy } from '$lib/time';
import { cached } from './cache';
import { buildOverpassQuery, fetchOhm, normalizeOhm } from './ohm';
import { fetchGeonames, normalizeGeonames } from './geonames';
import { buildOsmQuery, fetchOsm, normalizeOsm } from './osm';
import { fetchWikidataBox, fetchWikidataItems, normalizeWikidata, wdOptionsKey } from './wikidata';
import { fetchCommons, fetchWikipedia, normalizeCommons, normalizeWikipedia } from './wikimedia';

export const MAX_SPAN_DEG = 0.12; // ≈ 13 km north–south; less east–west away from the equator

// ----------------------------------------------------------------------------- geometry helpers

function allCoords(g: GeoJSON.Geometry): number[][] {
	const out: number[][] = [];
	const walk = (c: unknown): void => {
		if (Array.isArray(c) && typeof c[0] === 'number') out.push(c as number[]);
		else if (Array.isArray(c)) c.forEach(walk);
	};
	if ('coordinates' in g) walk(g.coordinates);
	return out;
}

export function centroid(g: GeoJSON.Geometry): [number, number] {
	const c = allCoords(g);
	const x = c.reduce((a, p) => a + p[0], 0) / c.length;
	const y = c.reduce((a, p) => a + p[1], 0) / c.length;
	return [+x.toFixed(7), +y.toFixed(7)];
}

function pointInRing(pt: number[], ring: number[][]): boolean {
	let inside = false;
	for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
		const [xi, yi] = ring[i];
		const [xj, yj] = ring[j];
		if (yi > pt[1] !== yj > pt[1] && pt[0] < ((xj - xi) * (pt[1] - yi)) / (yj - yi) + xi) inside = !inside;
	}
	return inside;
}

function pointInGeom(pt: number[], g: GeoJSON.Geometry): boolean {
	if (g.type === 'Polygon') return pointInRing(pt, g.coordinates[0]);
	if (g.type === 'MultiPolygon') return g.coordinates.some((p) => pointInRing(pt, p[0]));
	return false;
}

const metres = (a: number[], b: number[]) => {
	const dx = (a[0] - b[0]) * 111320 * Math.cos((a[1] * Math.PI) / 180);
	const dy = (a[1] - b[1]) * 110574;
	return Math.hypot(dx, dy);
};

/** pg_trgm-style similarity, good enough to pair "Palace Theater" with "Palace Theatre". */
function similarity(a: string, b: string): number {
	const grams = (s: string) => {
		const set = new Set<string>();
		for (const w of s.toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter(Boolean)) {
			const p = `  ${w} `;
			for (let i = 0; i < p.length - 2; i++) set.add(p.slice(i, i + 3));
		}
		return set;
	};
	const A = grams(a);
	const B = grams(b);
	let inter = 0;
	for (const g of A) if (B.has(g)) inter++;
	return inter / (A.size + B.size - inter || 1);
}

// ----------------------------------------------------------------------------- combine sources

/** Fold a candidate from another source into a base one: the base's shape and dates win, gaps get filled. */
function mergeInto(base: Candidate, other: Candidate): Candidate {
	const names = [...base.names];
	if (!base.unnamed && base.name.toLowerCase() !== other.name.toLowerCase()) {
		names.push({ name: other.name, name_type: 'alternate', source: other.fact_source });
	}
	for (const n of other.names) if (!names.some((x) => x.name.toLowerCase() === n.name.toLowerCase())) names.push(n);
	const attributes = [...base.attributes];
	for (const a of other.attributes) if (!attributes.some((x) => x.key === a.key)) attributes.push(a);
	const datesFromOther = !base.exists_from && !!other.exists_from;
	return {
		...base,
		key: `${base.key}|${other.key}`,
		origin: 'both',
		name: base.unnamed ? other.name : base.name,
		unnamed: false,
		summary: base.summary ?? other.summary,
		exists_from: base.exists_from ?? other.exists_from,
		exists_from_precision: base.exists_from ? base.exists_from_precision : other.exists_from_precision,
		exists_to: base.exists_to ?? other.exists_to,
		exists_to_precision: base.exists_to ? base.exists_to_precision : other.exists_to_precision,
		fact_source: datesFromOther ? other.fact_source : base.fact_source,
		kind: base.kind === 'organization' && other.kind !== 'organization' ? other.kind : base.kind,
		geometry: base.geometry ?? other.geometry,
		geometry_source: base.geometry ? base.geometry_source : other.geometry_source,
		role: base.geometry ? base.role : other.role,
		names,
		attributes,
		tags: [...new Set([...base.tags, ...other.tags])],
		ext: [...base.ext, ...other.ext],
		wikidata: base.wikidata ?? other.wikidata,
		image_url: base.image_url ?? other.image_url,
		status: base.status ?? other.status,
		classes: [...new Set([...other.classes, ...base.classes])]
	};
}

/** Add one more source's candidates onto the combined list, merging likely duplicates. */
function combineLayer(out: Candidate[], layer: Candidate[]): Candidate[] {
	const limit = out.length; // only merge into earlier sources, never into this layer's own rows
	const used = new Set<number>();
	for (const w of layer) {
		const pt = w.geometry?.type === 'Point' ? w.geometry.coordinates : null;
		const ok = (idx: number) => idx < limit && !used.has(idx) && out[idx].kind !== 'media';
		// 1. same Wikidata item
		let i = w.wikidata ? out.findIndex((c, idx) => ok(idx) && c.wikidata === w.wikidata) : -1;
		// 2. point inside a footprint (unnamed, or similarly named)
		if (i < 0 && pt && ['building', 'site'].includes(w.kind))
			i = out.findIndex(
				(c, idx) =>
					ok(idx) && ['building', 'site'].includes(c.kind) && c.geometry &&
					pointInGeom(pt, c.geometry) && (c.unnamed || similarity(c.name, w.name) > 0.45)
			);
		// 3. similar name close by
		if (i < 0 && pt)
			i = out.findIndex(
				(c, idx) => ok(idx) && !c.unnamed && c.geometry && similarity(c.name, w.name) > 0.6 && metres(centroid(c.geometry), pt) < 120
			);
		if (i >= 0) {
			out[i] = mergeInto(out[i], w);
			used.add(i);
		} else out.push(w);
	}
	return out;
}

// ----------------------------------------------------------------------------- planning

export const SOURCE_LABEL: Record<ImportSource, string> = {
	ohm: 'OHM', osm: 'OpenStreetMap', wikidata: 'Wikidata', wikipedia: 'Wikipedia', commons: 'Commons', geonames: 'GeoNames'
};

const dim = (g: GeoJSON.Geometry | null) => (!g ? -1 : g.type.includes('Polygon') ? 2 : g.type.includes('LineString') ? 1 : 0);
const range = (c: Candidate) =>
	c.exists_from || c.exists_to
		? `${c.exists_from ? formatFuzzy(c.exists_from, c.exists_from_precision) : '?'} – ${c.exists_to ? formatFuzzy(c.exists_to, c.exists_to_precision) : ''}`.trim()
		: null;
const shapeLabel = (c: Candidate) => {
	const d = dim(c.geometry);
	return d === 2 ? 'footprint' : d === 1 ? 'line' : d === 0 ? 'point' : 'no location';
};

/** Sources sometimes contradict themselves; never let that block an import. */
function sanitize(c: Candidate): Candidate {
	if (c.exists_from && c.exists_to && c.exists_to < c.exists_from) {
		return { ...c, exists_to: null, issues: [...(c.issues ?? []), `⚠ end ${c.exists_to.slice(0, 4)} is before start ${c.exists_from.slice(0, 4)}: end ignored`] };
	}
	return c;
}

function planItem(raw: Candidate, m: MatchInfo | null): PlanItem {
	const c = sanitize(raw);
	const changes: string[] = [...(c.issues ?? [])];
	const src = [...new Set(c.ext.map((e) => SOURCE_LABEL[e.source]))].join(' + ');
	if (!m) {
		changes.push(`new ${c.kind} from ${src}`);
		if (range(c)) changes.push(`dates ${range(c)}`);
		changes.push(shapeLabel(c));
		if (c.names.length) changes.push(`${c.names.length} other name${c.names.length > 1 ? 's' : ''}`);
		for (const a of c.attributes) if (a.key !== 'wikidata') changes.push(`${a.key.replace(/_/g, ' ')}: ${a.value}`);
		for (const t of c.tags) changes.push(`tag ${t}`);
		if (c.image_url) changes.push('Commons image link');
		if (c.media) changes.push(`${c.media.media_type}${c.media.rights ? ` · ${c.media.rights}` : ''}`);
		return { key: c.key, candidate: c, match: null, action: 'create', changes, addShape: true };
	}
	if (!m.exists_from && c.exists_from) changes.push(`+ start ${formatFuzzy(c.exists_from, c.exists_from_precision)}`);
	if (!m.exists_to && c.exists_to) changes.push(`+ end ${formatFuzzy(c.exists_to, c.exists_to_precision)}`);
	const d = dim(c.geometry);
	const addShape = (d >= 1 && !m.has_shape) || (d === 0 && !m.has_geometry);
	if (addShape) changes.push(`+ ${shapeLabel(c)}`);
	const known = new Set(m.names.map((n) => n.toLowerCase()));
	const newNames = [...(c.unnamed ? [] : [c.name]), ...c.names.map((n) => n.name)].filter((n) => !known.has(n.toLowerCase()));
	for (const n of [...new Set(newNames)]) changes.push(`+ name “${n}”`);
	for (const a of c.attributes) if (!m.attributes.includes(a.key)) changes.push(`+ ${a.key.replace(/_/g, ' ')}: ${a.value}`);
	for (const t of c.tags) if (!m.tags.includes(t)) changes.push(`+ tag ${t}`);
	if (!m.summary && c.summary) changes.push('+ summary');
	const newExt = c.ext.filter((e) => !m.ext.includes(`${e.source}:${e.id}`));
	if (newExt.length) changes.push(`+ link ${newExt.map((e) => (e.source === 'ohm' ? 'OHM ' : '') + e.id).slice(0, 2).join(', ')}${newExt.length > 2 ? '…' : ''}`);
	if (c.image_url) changes.push('+ Commons image link');
	const meaningful = changes.filter((x) => !x.startsWith('+ link') && !x.startsWith('⚠')).length > 0;
	return { key: c.key, candidate: c, match: m, action: meaningful ? 'merge' : 'skip', changes: changes.length ? changes : ['already up to date'], addShape };
}

// ----------------------------------------------------------------------------- entry point

export interface PreviewKeys {
	geonamesUser?: string;
}

export async function buildPreview(sb: SupabaseClient, opts: ImportOptions, userAgent: string, lang = 'en', keys: PreviewKeys = {}): Promise<PreviewResult> {
	const [w, s, e, n] = opts.bbox;
	if (![w, s, e, n].every(Number.isFinite) || e <= w || n <= s) throw new Error('Pick an area on the map first.');
	if (e - w > MAX_SPAN_DEG || n - s > MAX_SPAN_DEG)
		throw new Error('That area is too large for one import. Zoom in to a neighborhood or a few blocks at a time.');

	const bb = opts.bbox.join(',');
	const warnings: string[] = [];
	const { data: hk } = await sb.from('attribute_keys').select('unit').eq('id', 'height').maybeSingle();
	const heightUnit: string | null = hk?.unit ?? 'm';
	let ohm: Candidate[] = [];
	let osm: Candidate[] = [];
	let wd: Candidate[] = [];
	let wp: Candidate[] = [];
	let geo: Candidate[] = [];
	let commons: Candidate[] = [];

	const tasks: Promise<void>[] = [];
	const task = (label: string, run: () => Promise<void>) => tasks.push(run().catch((err) => void warnings.push(`${label} fetch failed: ${(err as Error).message}`)));
	if (opts.ohm.enabled) {
		task('OpenHistoricalMap', () =>
			// Always fetch all buildings: unnamed footprints can still give Wikidata items their real shape
			cached(`ohm:${buildOverpassQuery({ ...opts.ohm, unnamedBuildings: true }, opts.bbox)}`, () =>
				fetchOhm({ ...opts.ohm, unnamedBuildings: true }, opts.bbox, userAgent)
			).then(({ elements, remark }) => {
				if (remark) warnings.push(`OpenHistoricalMap: ${remark}`);
				ohm = normalizeOhm(elements, lang, heightUnit);
			})
		);
	}
	if (opts.osm.enabled && (opts.osm.businesses || opts.osm.places || opts.osm.buildings)) {
		task('OpenStreetMap', () =>
			cached(`osm:${buildOsmQuery(opts.osm, opts.bbox)}`, () => fetchOsm(opts.osm, opts.bbox, userAgent)).then(({ elements, remark }) => {
				if (remark) warnings.push(`OpenStreetMap: ${remark}`);
				osm = normalizeOsm(elements, lang, heightUnit);
			})
		);
	}
	if (opts.wikidata.enabled) {
		task('Wikidata', () =>
			cached(`wd:${lang}:${bb}:${wdOptionsKey(opts.wikidata)}`, () => fetchWikidataBox(opts.bbox, userAgent, lang, opts.wikidata)).then(
				(rows) => void (wd = normalizeWikidata(rows, opts.wikidata, heightUnit))
			)
		);
	}
	if (opts.wikipedia.enabled) {
		task('Wikipedia', () =>
			cached(`wp:${lang}:${bb}`, () => fetchWikipedia(opts.bbox, userAgent, lang)).then(({ pages, host, warning }) => {
				if (warning) warnings.push(warning);
				wp = normalizeWikipedia(pages, host);
			})
		);
	}
	if (opts.geonames.enabled) {
		if (!keys.geonamesUser) warnings.push('GeoNames needs a free account name: an admin can add it under Admin → Settings → Secrets.');
		else {
			task('GeoNames', () =>
				cached(`geo:${lang}:${bb}`, () => fetchGeonames(opts.bbox, userAgent, lang, keys.geonamesUser!)).then(({ rows, truncated }) => {
					if (truncated) warnings.push('GeoNames returned only the first 1000 features; draw a smaller box to see everything.');
					geo = normalizeGeonames(rows, lang);
				})
			);
		}
	}
	if (opts.commons.enabled) {
		task('Wikimedia Commons', () =>
			cached(`commons:${bb}`, () => fetchCommons(opts.bbox, userAgent)).then(({ files, warning }) => {
				if (warning) warnings.push(warning);
				commons = normalizeCommons(files, opts.commons);
			})
		);
	}
	await Promise.all(tasks);

	// Wikidata items that other sources point at (wikidata=* tags, Wikipedia pages) but that have no coordinates in the box
	if (opts.wikidata.enabled) {
		const have = new Set(wd.map((c) => c.wikidata));
		const missing = [...new Set([...ohm, ...osm, ...wp].map((c) => c.wikidata).filter((q): q is string => !!q && !have.has(q)))].slice(0, 200);
		if (missing.length) {
			try {
				wd.push(...normalizeWikidata(await fetchWikidataItems(missing, userAgent, lang, opts.wikidata), opts.wikidata, heightUnit));
			} catch (err) {
				warnings.push(`Wikidata enrichment failed: ${(err as Error).message}`);
			}
		}
	}

	const counts = { ohm: ohm.length, osm: osm.length, wikidata: wd.length, wikipedia: wp.length, geonames: geo.length, commons: commons.length, combined: 0, hiddenUnnamed: 0 };
	let cands: Candidate[] = [...ohm];
	for (const layer of [osm, wd, wp, geo]) cands = combineLayer(cands, layer);
	cands.push(...commons);
	counts.combined = cands.filter((c) => c.origin === 'both').length;
	if (!opts.ohm.unnamedBuildings || !opts.ohm.buildings) {
		const before = cands.length;
		cands = cands.filter((c) => !(c.unnamed && c.kind === 'building'));
		counts.hiddenUnnamed = opts.ohm.buildings ? before - cands.length : 0;
	}
	if (opts.ohm.enabled && !ohm.length && !warnings.length) warnings.push('OpenHistoricalMap has nothing mapped in this area for the chosen categories.');
	if (!opts.ohm.buildings) cands = cands.filter((c) => !(c.origin === 'ohm' && c.kind === 'building'));

	// Match against existing pages (in chunks to keep requests reasonable)
	const matches: Record<string, MatchInfo> = {};
	for (let i = 0; i < cands.length; i += 250) {
		const chunk = cands.slice(i, i + 250).map((c) => {
			const pt = c.geometry ? centroid(c.geometry) : null;
			return {
				key: c.key,
				name: c.unnamed ? null : c.name,
				kind: c.kind,
				wikidata: c.wikidata,
				ext: c.ext.map((x) => ({ source: x.source, id: x.id })),
				lon: pt?.[0] ?? null,
				lat: pt?.[1] ?? null,
				geom: c.geometry && dim(c.geometry) === 2 ? c.geometry : null
			};
		});
		const { data, error } = await sb.rpc('match_import_candidates', { p_candidates: chunk });
		if (error) throw new Error(`Matching failed: ${error.message}`);
		Object.assign(matches, data ?? {});
	}

	const order = { create: 0, merge: 1, skip: 2 } as const;
	const items = cands
		.map((c) => planItem(c, matches[c.key] ?? null))
		.sort((a, b) => order[a.action] - order[b.action] || Number(a.candidate.unnamed) - Number(b.candidate.unnamed) || a.candidate.name.localeCompare(b.candidate.name));

	return { bbox: opts.bbox, fetchedAt: new Date().toISOString(), counts, warnings, items };
}

/** Turn approved preview rows into the payload apply_import() expects. */
export function toApplyPayload(items: PlanItem[], bbox: number[], kinds: Set<string>) {
	const sources = new Set<string>();
	const out = items
		.filter((i) => i.action === 'create' || i.action === 'merge')
		.map((i) => {
			const c = sanitize(i.candidate);
			if (!kinds.has(c.kind)) throw new Error(`Unknown kind “${c.kind}” for ${c.name}`);
			if (i.action === 'merge' && !i.match?.entity_id) throw new Error(`Nothing to merge “${c.name}” into`);
			const includeShape = i.action === 'create' ? !!c.geometry : i.addShape && !!c.geometry;
			if (includeShape && c.geometry_source) sources.add(c.geometry_source);
			sources.add(c.fact_source);
			if (c.image_url) sources.add('wikidata');
			for (const x of c.ext) sources.add(x.source);
			for (const x of [...c.names, ...c.attributes]) sources.add(x.source);
			const names = [...c.names];
			if (i.action === 'merge' && !c.unnamed) names.unshift({ name: c.name, name_type: 'alternate', source: c.fact_source });
			return {
				action: i.action,
				entity_id: i.match?.entity_id ?? null,
				kind: c.kind,
				name: c.name.slice(0, 200),
				summary: c.summary,
				exists_from: c.exists_from,
				exists_from_precision: c.exists_from_precision,
				exists_to: c.exists_to,
				exists_to_precision: c.exists_to_precision,
				confidence: c.approximate ? 'approximate' : 'probable',
				geometry: includeShape ? c.geometry : null,
				geometry_source: c.geometry_source,
				geometry_ref: c.ext.map((x) => `${x.source}:${x.id}`).slice(0, 3).join(', '),
				role: c.role,
				fact_source: c.fact_source,
				// An end date means it left the record; the lifespan end makes it a ghost. We don't
				// guess *how* it ended (demolished? renamed? moved?), so no condition is set.
				status: c.status ?? null,
				names,
				attributes: c.attributes,
				tags: c.tags,
				ext: c.ext,
				image_url: c.image_url,
				media: i.action === 'create' ? (c.media ?? null) : null,
				event_type: c.event_type ?? null
			};
		});
	return { sources: [...sources], bbox, items: out };
}
