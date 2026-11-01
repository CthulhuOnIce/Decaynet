import type { Precision } from './types';

const MONTHS = [
	'January', 'February', 'March', 'April', 'May', 'June',
	'July', 'August', 'September', 'October', 'November', 'December'
];

export interface FuzzyDate {
	date: string | null;
	precision: Precision;
	approximate: boolean;
}

const pad = (n: number) => String(n).padStart(2, '0');

/**
 * Parse the free-form dates historians actually write:
 *   1926 · 1926-05 · 1926-05-12 · May 1926 · May 12, 1926
 *   1920s (decade) · 1900s / 19th century (century)
 *   c. 1926 · ca 1926 · ~1926 · 1926? (flagged approximate)
 */
export function parseFuzzyDate(input: string | null | undefined): FuzzyDate | null {
	if (input == null) return null;
	let s = String(input).trim();
	if (!s) return null;

	let approximate = false;
	const approx = /^(c\.?|ca\.?|circa|~|about|abt\.?)\s*/i;
	if (approx.test(s)) {
		approximate = true;
		s = s.replace(approx, '');
	}
	if (s.endsWith('?')) {
		approximate = true;
		s = s.slice(0, -1).trim();
	}

	let m: RegExpMatchArray | null;
	if ((m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/)))
		return { date: `${m[1]}-${pad(+m[2])}-${pad(+m[3])}`, precision: 'day', approximate };
	if ((m = s.match(/^(\d{4})-(\d{1,2})$/)))
		return { date: `${m[1]}-${pad(+m[2])}-01`, precision: 'month', approximate };
	if ((m = s.match(/^(\d{1,2})(st|nd|rd|th)\s+century$/i))) {
		const start = (+m[1] - 1) * 100;
		return { date: `${String(start).padStart(4, '0')}-01-01`, precision: 'century', approximate };
	}
	if ((m = s.match(/^(\d{2})00s$/)))
		return { date: `${m[1]}00-01-01`, precision: 'century', approximate };
	if ((m = s.match(/^(\d{3})0s$/)))
		return { date: `${m[1]}0-01-01`, precision: 'decade', approximate };
	if ((m = s.match(/^(\d{4})$/))) return { date: `${m[1]}-01-01`, precision: 'year', approximate };

	const monthIdx = (name: string) =>
		MONTHS.findIndex((mo) => mo.toLowerCase().startsWith(name.toLowerCase().slice(0, 3)));
	if ((m = s.match(/^([A-Za-z]+)\.?\s+(\d{1,2}),?\s+(\d{4})$/))) {
		const mi = monthIdx(m[1]);
		if (mi >= 0) return { date: `${m[3]}-${pad(mi + 1)}-${pad(+m[2])}`, precision: 'day', approximate };
	}
	if ((m = s.match(/^(\d{1,2})\s+([A-Za-z]+)\.?\s+(\d{4})$/))) {
		const mi = monthIdx(m[2]);
		if (mi >= 0) return { date: `${m[3]}-${pad(mi + 1)}-${pad(+m[1])}`, precision: 'day', approximate };
	}
	if ((m = s.match(/^([A-Za-z]+)\.?\s+(\d{4})$/))) {
		const mi = monthIdx(m[1]);
		if (mi >= 0) return { date: `${m[2]}-${pad(mi + 1)}-01`, precision: 'month', approximate };
	}
	if (/^(unknown|\?|n\/a)$/i.test(s)) return null;
	throw new Error(`Couldn't read the date “${input}”. Try 1926, 1920s, c. 1926, May 1926 or 1926-05-12.`);
}

/** Render a fuzzy date the way a reader expects it. */
export function formatFuzzy(date: string | null | undefined, precision: Precision | null = 'day'): string {
	if (!date) return '?';
	const [y, mo, d] = date.slice(0, 10).split('-').map(Number);
	switch (precision) {
		case 'day':
			return `${MONTHS[mo - 1].slice(0, 3)} ${d}, ${y}`;
		case 'month':
			return `${MONTHS[mo - 1]} ${y}`;
		case 'decade':
			return `${Math.floor(y / 10) * 10}s`;
		case 'century':
			return `${Math.floor(y / 100) * 100}s`;
		case 'unknown':
			return `?${y}`;
		default:
			return String(y);
	}
}

export function formatRange(
	from: string | null | undefined,
	fromP: Precision | null,
	to: string | null | undefined,
	toP: Precision | null
): string {
	if (!from && !to) return '';
	if (from && !to) return `${formatFuzzy(from, fromP)} –`;
	if (!from && to) return `– ${formatFuzzy(to, toP)}`;
	const a = formatFuzzy(from, fromP);
	const b = formatFuzzy(to, toP);
	return a === b ? a : `${a} – ${b}`;
}

/** Inverse of parseFuzzyDate, for pre-filling forms. */
export function toFuzzyInput(date: string | null | undefined, precision: Precision | null): string {
	if (!date) return '';
	const [y, mo, d] = date.slice(0, 10).split('-');
	switch (precision) {
		case 'day':
			return `${y}-${mo}-${d}`;
		case 'month':
			return `${y}-${mo}`;
		case 'decade':
			return `${y.slice(0, 3)}0s`;
		case 'century':
			return `${y.slice(0, 2)}00s`;
		default:
			return y;
	}
}

export const yearOf = (date: string | null | undefined) => (date ? Number(date.slice(0, 4)) : null);

/** The time machine samples each year at mid-year, so a change "in 1975" is visible at 1975. */
export const yearToDate = (year: number) => `${String(year).padStart(4, '0')}-07-01`;

/** Last day covered by a fuzzy date ("1950s" → 1959-12-31). */
export function precisionEndInclusive(date: string, precision: Precision): string {
	const y = Number(date.slice(0, 4));
	switch (precision) {
		case 'year':
			return `${String(y).padStart(4, '0')}-12-31`;
		case 'decade':
			return `${String(Math.floor(y / 10) * 10 + 9).padStart(4, '0')}-12-31`;
		case 'century':
			return `${String(Math.floor(y / 100) * 100 + 99).padStart(4, '0')}-12-31`;
		case 'month': {
			const d = new Date(Date.UTC(y, Number(date.slice(5, 7)), 0));
			return d.toISOString().slice(0, 10);
		}
		default:
			return date;
	}
}
