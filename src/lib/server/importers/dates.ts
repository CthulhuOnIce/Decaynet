import { parseFuzzyDate } from '$lib/time';
import type { Precision } from '$lib/types';

/**
 * Parse OSM/OHM-style dates (ISO 8601 subsets and common EDTF forms):
 *   1926 · 1926-05 · 1926-05-12 · ~1926 · 1926~ · 1926? · 192X / 192u (decade) · 19XX (century)
 *   1920s · c. 1926 · "before 1930" → null
 */
export function parseOsmDate(raw: string | undefined | null): { date: string; precision: Precision; approximate: boolean } | null {
	if (!raw) return null;
	let s = raw.trim();
	let approximate = false;
	if (/[~?%]/.test(s)) {
		approximate = true;
		s = s.replace(/[~?%]/g, '');
	}
	let m: RegExpMatchArray | null;
	if ((m = s.match(/^(\d{3})[Xux]$/))) return { date: `${m[1]}0-01-01`, precision: 'decade', approximate };
	if ((m = s.match(/^(\d{2})[Xux]{2}$/))) return { date: `${m[1]}00-01-01`, precision: 'century', approximate };
	if ((m = s.match(/^(\d{4}-\d{2}-\d{2})T/))) s = m[1];
	if (/^-/.test(s)) return null; // BCE: out of scope here
	try {
		const p = parseFuzzyDate(s);
		return p?.date ? { date: p.date, precision: p.precision, approximate: approximate || p.approximate } : null;
	} catch {
		return null;
	}
}

/** Wikidata time value + precision (7 century · 8 decade · 9 year · 10 month · 11 day). */
export function parseWikidataTime(value: string | undefined, precision: string | undefined) {
	if (!value) return null;
	const m = value.match(/^\+?(\d{4})-(\d{2})-(\d{2})/);
	if (!m) return null;
	const p = Number(precision ?? 9);
	const prec: Precision = p >= 11 ? 'day' : p === 10 ? 'month' : p === 9 ? 'year' : p === 8 ? 'decade' : 'century';
	const date = prec === 'day' ? `${m[1]}-${m[2]}-${m[3]}` : prec === 'month' ? `${m[1]}-${m[2]}-01` : `${m[1]}-01-01`;
	return { date, precision: prec, approximate: false };
}
