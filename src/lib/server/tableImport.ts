import type { SupabaseClient } from '@supabase/supabase-js';
import type { SiteSettings, Vocabulary } from '$lib/types';
import { formatFuzzy, formatRange, parseFuzzyDate, type FuzzyDate } from '$lib/time';
import { splitList, unitFromAddress, type SheetOptions, type SheetRow } from '$lib/tableImport';
import { geocodeAddresses } from './geocode';
import { FormError } from './forms';

export const MAX_ROWS = 2000;
/** Nominatim asks for no bulk geocoding: a few lookups per preview, one a second. */
export const MAX_GEOCODE = 25;

export interface Sheet {
	headers: string[];
	rows: string[][];
	mapping: string[];
	options: SheetOptions;
}

/** What one row says, read and checked (dates parsed, kind and link type resolved). */
interface Norm {
	n: number;
	name: string;
	kind: string;
	address: string | null;
	unit: string | null;
	place: string | null;
	link_as: string;
	life: { from: FuzzyDate | null; to: FuzzyDate | null };
	at: { from: FuzzyDate | null; to: FuzzyDate | null };
	when: string;
	tags: string[];
	names: string[];
	summary: string | null;
	note: string | null;
	source_detail: string | null;
	attributes: { key: string; value: unknown }[];
	lat: number | null;
	lon: number | null;
	issues: string[];
}

export function readSheet(raw: string | null): Sheet {
	let s: Sheet;
	try {
		s = JSON.parse(raw ?? '');
	} catch {
		throw new FormError('The sheet could not be read. Paste or choose it again.');
	}
	if (!Array.isArray(s?.headers) || !Array.isArray(s?.rows) || !Array.isArray(s?.mapping) || !s.options) throw new FormError('The sheet could not be read.');
	if (!s.mapping.includes('name')) throw new FormError('Pick the column that holds the names.');
	if (s.rows.length > MAX_ROWS) throw new FormError(`That's ${s.rows.length} rows; import at most ${MAX_ROWS} at a time.`);
	return s;
}

const lc = (s: string) => s.trim().toLowerCase();

export function normalize(sheet: Sheet, vocab: Vocabulary): Norm[] {
	const { headers, rows, mapping, options } = sheet;
	const col = (field: string) => mapping.indexOf(field);
	const at = (r: string[], field: string) => {
		const i = col(field);
		const v = i < 0 ? '' : (r[i] ?? '').trim();
		return v === '' ? null : v;
	};
	const date = (v: string | null, what: string, issues: string[]) => {
		if (!v) return null;
		try {
			return parseFuzzyDate(v);
		} catch {
			issues.push(`can't read the ${what} “${v}”`);
			return null;
		}
	};
	const kindOf = (v: string | null, issues: string[]) => {
		if (!v) return options.kind;
		const k = vocab.kinds.find((k) => lc(k.id) === lc(v) || lc(k.label) === lc(v) || lc(k.plural) === lc(v));
		if (!k) issues.push(`unknown kind “${v}”: using ${vocab.kinds.find((x) => x.id === options.kind)?.label ?? options.kind}`);
		return k?.id ?? options.kind;
	};
	const relOf = (v: string | null, issues: string[]) => {
		if (!v) return options.link_as;
		const t = vocab.relationTypes.find((t) => lc(t.id) === lc(v) || lc(t.label) === lc(v) || lc(t.id.replace(/_/g, ' ')) === lc(v));
		if (!t) issues.push(`unknown link “${v}”: using “${vocab.relationTypes.find((x) => x.id === options.link_as)?.label ?? options.link_as}”`);
		return t?.id ?? options.link_as;
	};
	const listed = options.year?.trim() || null;
	const out: Norm[] = [];
	rows.forEach((r, k) => {
		const name = (at(r, 'name') ?? '').replace(/\s+/g, ' ').trim();
		if (!name) return; // blank lines and section headings in a directory
		const issues: string[] = [];
		let address = at(r, 'address');
		let unit = at(r, 'unit');
		if (address && !unit) ({ address, unit } = unitFromAddress(address));
		const from = date(at(r, 'from'), 'start', issues);
		const to = date(at(r, 'to'), 'end', issues);
		const year = date(at(r, 'year') ?? (from || to ? null : listed), 'year', issues);
		const linkFrom = from ?? (to ? null : year);
		const linkTo = to ?? (from ? null : year);
		if (from?.date && to?.date && from.date > to.date) issues.push('it ends before it starts');
		const attributes: { key: string; value: unknown }[] = [];
		mapping.forEach((m, i) => {
			if (!m.startsWith('attr:')) return;
			const v = (r[i] ?? '').trim();
			if (!v) return;
			const key = vocab.attributeKeys.find((a) => a.id === m.slice(5));
			if (!key) return;
			if (key.value_type === 'number' || key.value_type === 'year') {
				const num = Number(v.replace(/[, ]/g, ''));
				if (Number.isFinite(num)) attributes.push({ key: key.id, value: num });
				else issues.push(`${key.label} “${v}” isn't a number`);
			} else if (key.value_type === 'boolean') attributes.push({ key: key.id, value: /^(y|yes|true|1|x)$/i.test(v) });
			else attributes.push({ key: key.id, value: v });
		});
		const num = (v: string | null, lo: number, hi: number, what: string) => {
			if (!v) return null;
			const x = Number(v);
			if (Number.isFinite(x) && x >= lo && x <= hi) return x;
			issues.push(`${what} “${v}” isn't one`);
			return null;
		};
		const lat = num(at(r, 'lat'), -90, 90, 'latitude');
		const lon = num(at(r, 'lon'), -180, 180, 'longitude');
		out.push({
			n: k + 2, // the spreadsheet's own row number (row 1 holds the headers)
			name,
			kind: kindOf(at(r, 'kind'), issues),
			address,
			unit,
			place: at(r, 'place'),
			link_as: relOf(at(r, 'link_as'), issues),
			life: { from, to },
			at: { from: linkFrom, to: linkTo },
			when: from || to
				? formatRange(from?.date ?? null, from?.precision ?? 'year', to?.date ?? null, to?.precision ?? 'year')
				: year
					? `in ${formatFuzzy(year.date, year.precision)}`
					: 'undated',
			tags: splitList(at(r, 'tags')),
			names: splitList(at(r, 'names')),
			summary: at(r, 'summary'),
			note: at(r, 'note'),
			// a bare page number reads as one: "214" → "p. 214"
			source_detail: ((d) => (d && /^\d+[a-z]?$/i.test(d) ? `p. ${d}` : d))(at(r, 'source_detail')),
			attributes,
			lat,
			lon,
			issues
		});
	});
	void headers;
	return out;
}

const SPATIAL_LINKLESS = new Set(['building', 'site', 'parcel', 'street', 'infrastructure', 'district', 'water', 'landform']);

/** Match every row, then (if asked) look up a few unmatched addresses. */
export async function preview(sb: SupabaseClient, sheet: Sheet, vocab: Vocabulary, settings: SiteSettings, origin: string) {
	const norm = normalize(sheet, vocab);
	if (!norm.length) throw new FormError('No rows with a name in them.');
	const { data, error } = await sb.rpc('match_table_rows', {
		p_rows: norm.map((r) => ({
			i: r.n,
			name: r.name,
			kind: r.kind,
			place: r.place,
			address: r.address,
			unit: r.unit,
			at: r.at.from?.date ?? r.at.to?.date ?? null,
			tags: r.tags
		}))
	});
	if (error) throw new FormError(error.message);
	type Match = {
		i: number;
		same: SheetRow['same'];
		similar: SheetRow['similar'];
		place: SheetRow['place'];
		place_how: SheetRow['place_how'];
		space: SheetRow['space'];
		tags: { found: { id: string; label: string }[]; missing: string[] };
	};
	const byRow = new Map((data as Match[]).map((m) => [m.i, m]));
	const rows: SheetRow[] = norm.map((r) => {
		const m = byRow.get(r.n)!;
		const issues = [...r.issues];
		// a storefront row's unit is its own number, not one to look for
		const isSpace = r.kind === 'space';
		const place = m.space && !isSpace ? { ...m.space, kind: 'space' } : m.place;
		if (r.place && !m.place) issues.push(`no building called “${r.place}”`);
		if (r.unit && m.place && !m.space && !isSpace) issues.push(`no storefront “${r.unit}” in ${m.place.name}: linked to the building`);
		if (m.place_how === 'address, other years') issues.push(`${m.place?.name} has that address only in other years`);
		const rel = vocab.relationTypes.find((t) => t.id === r.link_as);
		if (place && rel && !SPATIAL_LINKLESS.has(r.kind) && r.kind !== 'space') {
			if ((rel.subject_kinds && !rel.subject_kinds.includes(r.kind)) || (rel.object_kinds && !rel.object_kinds.includes(place.kind)))
				issues.push(`“${rel.label}” doesn't link a ${r.kind} to a ${place.kind}`);
		}
		return {
			n: r.n,
			name: r.name,
			kind: r.kind,
			address: r.address,
			unit: r.unit,
			when: r.when,
			link_as: r.link_as,
			same: m.same,
			similar: m.similar,
			shares: null,
			place,
			place_how: m.place_how,
			space: isSpace ? null : m.space,
			tags: m.tags.found,
			missing_tags: m.tags.missing,
			lat: r.lat,
			lon: r.lon,
			issues,
			use_existing: m.same?.id ?? null,
			place_id: place?.id ?? null,
			point: sheet.options.points && !place && r.lat != null && r.lon != null,
			include: true
		};
	});

	// one page per name and kind in a sheet: later rows go on the page the first one makes
	const first = new Map<string, number>();
	for (const r of rows) {
		if (r.same) continue;
		const key = `${r.kind}|${r.name.toLowerCase()}`;
		if (first.has(key)) r.shares = first.get(key)!;
		else first.set(key, r.n);
	}

	// a few addresses that match no building, looked up on today's map
	let geocoded = 0;
	if (sheet.options.geocode && sheet.options.points) {
		const want = new Map<string, SheetRow[]>();
		for (const r of rows) {
			if (r.place || r.lat != null || !r.address || SPATIAL_LINKLESS.has(r.kind)) continue;
			const key = r.address.toLowerCase();
			if (!want.has(key)) want.set(key, []);
			want.get(key)!.push(r);
		}
		for (const [, list] of [...want].slice(0, MAX_GEOCODE)) {
			const q = settings.region_name ? `${list[0].address}, ${settings.region_name}` : list[0].address!;
			const hit = (await geocodeAddresses(q, settings, origin))[0];
			if (!hit) continue;
			geocoded++;
			for (const r of list) {
				r.lat = hit.lat;
				r.lon = hit.lon;
				r.place_how = 'geocoded';
				r.point = true;
				r.issues.push(`placed at today's ${hit.label} (approximate: numbering may have changed)`);
			}
		}
		if (want.size > MAX_GEOCODE) rows.forEach((r) => r.place_how !== 'geocoded' && !r.place && r.address && want.has(r.address.toLowerCase()) && r.issues.push('not looked up (only the first 25 addresses are)'));
	}
	return { rows, geocoded };
}

export interface Choice {
	include: boolean;
	use_existing: string | null;
	place_id: string | null;
	point: boolean;
	lat: number | null;
	lon: number | null;
	tag_ids: string[];
}

/** The rows to write: the sheet read again, with the editor's choices from the preview. */
export function applyRows(sheet: Sheet, vocab: Vocabulary, choices: Record<string, Choice>) {
	const out = [];
	for (const r of normalize(sheet, vocab)) {
		const c = choices[String(r.n)];
		if (!c?.include) continue;
		const d = (f: FuzzyDate | null) => f?.date ?? null;
		const p = (f: FuzzyDate | null) => f?.precision ?? 'year';
		// a storefront row's unit is its own number
		const attributes = r.kind === 'space' && r.unit && !r.attributes.some((a) => a.key === 'unit_label') ? [...r.attributes, { key: 'unit_label', value: r.unit }] : r.attributes;
		out.push({
			name: r.name,
			kind: r.kind,
			entity_id: c.use_existing,
			summary: r.summary,
			names: r.names,
			tag_ids: c.tag_ids,
			attributes,
			from: d(r.life.from),
			from_p: p(r.life.from),
			to: d(r.life.to),
			to_p: p(r.life.to),
			place_id: c.place_id,
			predicate: r.kind === 'space' ? 'part_of' : r.link_as,
			at_from: d(r.at.from),
			at_from_p: p(r.at.from),
			at_to: d(r.at.to),
			at_to_p: p(r.at.to),
			note: r.note,
			source_detail: r.source_detail,
			address: r.address,
			unit: r.unit,
			lat: c.lat ?? r.lat,
			lon: c.lon ?? r.lon,
			point: c.point
		});
	}
	return out;
}
