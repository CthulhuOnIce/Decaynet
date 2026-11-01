import type { SupabaseClient } from '@supabase/supabase-js';
import type { Candidate, ImportOptions, MatchInfo, PlanItem, PreviewResult } from '$lib/importTypes';
import { formatFuzzy } from '$lib/time';
import { cached } from './cache';
import { buildOverpassQuery, fetchOhm, normalizeOhm } from './ohm';
import { fetchWikidataBox, fetchWikidataItems, normalizeWikidata } from './wikidata';

export const MAX_SPAN_DEG = 0.12; // ≈ 10 km × 13 km at Gary's latitude

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

// ----------------------------------------------------------------------------- combine OHM + Wikidata

function mergeInto(base: Candidate, wd: Candidate): Candidate {
	const names = [...base.names];
	if (base.unnamed) {
		// the OHM shape gets its name from Wikidata
	} else if (base.name.toLowerCase() !== wd.name.toLowerCase()) {
		names.push({ name: wd.name, name_type: 'alternate', source: 'wikidata' });
	}
	for (const n of wd.names) if (!names.some((x) => x.name.toLowerCase() === n.name.toLowerCase())) names.push(n);
	const attributes = [...base.attributes];
	for (const a of wd.attributes) if (!attributes.some((x) => x.key === a.key)) attributes.push(a);
	const datesFromWd = !base.exists_from && !!wd.exists_from;
	return {
		...base,
		key: `${base.key}|${wd.key}`,
		origin: 'both',
		name: base.unnamed ? wd.name : base.name,
		unnamed: false,
		summary: base.summary ?? wd.summary,
		exists_from: base.exists_from ?? wd.exists_from,
		exists_from_precision: base.exists_from ? base.exists_from_precision : wd.exists_from_precision,
		exists_to: base.exists_to ?? wd.exists_to,
		exists_to_precision: base.exists_to ? base.exists_to_precision : wd.exists_to_precision,
		fact_source: datesFromWd ? 'wikidata' : base.fact_source,
		kind: base.kind === 'organization' && wd.kind !== 'organization' ? wd.kind : base.kind,
		names,
		attributes,
		tags: [...new Set([...base.tags, ...wd.tags])],
		ext: [...base.ext, ...wd.ext],
		wikidata: wd.wikidata,
		image_url: wd.image_url,
		classes: [...new Set([...wd.classes, ...base.classes])]
	};
}

function combine(ohm: Candidate[], wd: Candidate[]): Candidate[] {
	const out = [...ohm];
	const used = new Set<number>();
	for (const w of wd) {
		const pt = w.geometry?.type === 'Point' ? w.geometry.coordinates : null;
		// 1. OHM feature tagged wikidata=Q…
		let i = out.findIndex((c, idx) => !used.has(idx) && c.origin === 'ohm' && c.wikidata === w.wikidata);
		// 2. Wikidata point inside an OHM footprint (unnamed, or similarly named)
		if (i < 0 && pt && ['building', 'site'].includes(w.kind))
			i = out.findIndex(
				(c, idx) =>
					!used.has(idx) && c.origin === 'ohm' && ['building', 'site'].includes(c.kind) && c.geometry &&
					pointInGeom(pt, c.geometry) && (c.unnamed || similarity(c.name, w.name) > 0.45)
			);
		// 3. Similar name close by
		if (i < 0 && pt)
			i = out.findIndex(
				(c, idx) =>
					!used.has(idx) && c.origin === 'ohm' && !c.unnamed && c.geometry &&
					similarity(c.name, w.name) > 0.6 && metres(centroid(c.geometry), pt) < 120
			);
		if (i >= 0) {
			out[i] = mergeInto(out[i], w);
			used.add(i);
		} else out.push(w);
	}
	return out;
}

// ----------------------------------------------------------------------------- planning

const dim = (g: GeoJSON.Geometry | null) => (!g ? -1 : g.type.includes('Polygon') ? 2 : g.type.includes('LineString') ? 1 : 0);
const range = (c: Candidate) =>
	c.exists_from || c.exists_to
		? `${c.exists_from ? formatFuzzy(c.exists_from, c.exists_from_precision) : '?'} – ${c.exists_to ? formatFuzzy(c.exists_to, c.exists_to_precision) : ''}`.trim()
		: null;
const shapeLabel = (c: Candidate) => {
	const d = dim(c.geometry);
	return d === 2 ? 'footprint' : d === 1 ? 'line' : d === 0 ? 'point' : 'no location';
};

function planItem(c: Candidate, m: MatchInfo | null): PlanItem {
	const changes: string[] = [];
	const src = c.origin === 'both' ? 'OHM + Wikidata' : c.origin === 'ohm' ? 'OHM' : 'Wikidata';
	if (!m) {
		changes.push(`new ${c.kind} from ${src}`);
		if (range(c)) changes.push(`dates ${range(c)}`);
		changes.push(shapeLabel(c));
		if (c.names.length) changes.push(`${c.names.length} other name${c.names.length > 1 ? 's' : ''}`);
		for (const a of c.attributes) if (a.key !== 'wikidata') changes.push(`${a.key.replace(/_/g, ' ')}: ${a.value}`);
		for (const t of c.tags) changes.push(`tag ${t}`);
		if (c.image_url) changes.push('Commons image link');
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
	const meaningful = changes.filter((x) => !x.startsWith('+ link')).length > 0;
	return { key: c.key, candidate: c, match: m, action: meaningful ? 'merge' : 'skip', changes: changes.length ? changes : ['already up to date'], addShape };
}

// ----------------------------------------------------------------------------- entry point

export async function buildPreview(sb: SupabaseClient, opts: ImportOptions, userAgent: string): Promise<PreviewResult> {
	const [w, s, e, n] = opts.bbox;
	if (![w, s, e, n].every(Number.isFinite) || e <= w || n <= s) throw new Error('Pick an area on the map first.');
	if (e - w > MAX_SPAN_DEG || n - s > MAX_SPAN_DEG)
		throw new Error('That area is too large for one import. Zoom in to a neighborhood or a few blocks at a time.');

	const warnings: string[] = [];
	let ohm: Candidate[] = [];
	let wd: Candidate[] = [];

	const tasks: Promise<void>[] = [];
	if (opts.ohm.enabled) {
		tasks.push(
			// Always fetch all buildings: unnamed footprints can still give Wikidata items their real shape
			cached(`ohm:${buildOverpassQuery({ ...opts.ohm, unnamedBuildings: true }, opts.bbox)}`, () =>
				fetchOhm({ ...opts.ohm, unnamedBuildings: true }, opts.bbox, userAgent)
			).then(({ elements, remark }) => {
				if (remark) warnings.push(`OpenHistoricalMap: ${remark}`);
				ohm = normalizeOhm(elements);
			}).catch((err) => void warnings.push(`OpenHistoricalMap fetch failed: ${(err as Error).message}`))
		);
	}
	if (opts.wikidata.enabled) {
		tasks.push(
			cached(`wd:${opts.bbox.join(',')}`, () => fetchWikidataBox(opts.bbox, userAgent))
				.then((rows) => void (wd = normalizeWikidata(rows, opts.wikidata)))
				.catch((err) => void warnings.push(`Wikidata fetch failed: ${(err as Error).message}`))
		);
	}
	await Promise.all(tasks);

	// Wikidata items that OHM features point at but that have no coordinates in the box
	if (opts.wikidata.enabled && ohm.length) {
		const have = new Set(wd.map((c) => c.wikidata));
		const missing = [...new Set(ohm.map((c) => c.wikidata).filter((q): q is string => !!q && !have.has(q)))].slice(0, 200);
		if (missing.length) {
			try {
				wd.push(...normalizeWikidata(await fetchWikidataItems(missing, userAgent), opts.wikidata));
			} catch (err) {
				warnings.push(`Wikidata enrichment failed: ${(err as Error).message}`);
			}
		}
	}

	const counts = { ohm: ohm.length, wikidata: wd.length, combined: 0, hiddenUnnamed: 0 };
	let cands = combine(ohm, wd);
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
			const c = i.candidate;
			if (!kinds.has(c.kind)) throw new Error(`Unknown kind “${c.kind}” for ${c.name}`);
			if (i.action === 'merge' && !i.match?.entity_id) throw new Error(`Nothing to merge “${c.name}” into`);
			const includeShape = i.action === 'create' ? !!c.geometry : i.addShape && !!c.geometry;
			if (includeShape && c.geometry_source) sources.add(c.geometry_source);
			sources.add(c.fact_source);
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
				status: null,
				names,
				attributes: c.attributes,
				tags: c.tags,
				ext: c.ext,
				image_url: c.image_url
			};
		});
	return { sources: [...sources], bbox, items: out };
}
