/*
 * Spreadsheet import: what a column can be, guessing it from the header, and
 * reading CSV / TSV (or cells pasted straight from a spreadsheet).
 */

export interface TableField {
	id: string;
	label: string;
	hint?: string;
	/** header words that mean this column (lower case) */
	match: string[];
}

export const TABLE_FIELDS: TableField[] = [
	{ id: 'name', label: 'Name', hint: 'required', match: ['name', 'business', 'business name', 'organization', 'organisation', 'company', 'firm', 'listing', 'occupant', 'tenant', 'person'] },
	{ id: 'address', label: 'Address', hint: '512 Broadway', match: ['address', 'addr', 'street address', 'location', 'street'] },
	{ id: 'unit', label: 'Unit / suite', hint: 'matches a storefront', match: ['unit', 'suite', 'ste', 'room', 'rm', 'apt', 'apartment', 'office', 'store'] },
	{ id: 'place', label: 'Building', hint: 'page name or link', match: ['building', 'place', 'premises', 'in building', 'located in'] },
	{ id: 'year', label: 'Listed in', hint: 'one year', match: ['year', 'listed', 'directory year', 'directory', 'date', 'seen'] },
	{ id: 'from', label: 'From', match: ['from', 'start', 'started', 'opened', 'open', 'since', 'established', 'est', 'founded', 'began'] },
	{ id: 'to', label: 'Until', match: ['to', 'until', 'end', 'ended', 'closed', 'close', 'moved'] },
	{ id: 'kind', label: 'Kind', hint: 'organization, person…', match: ['kind', 'page kind', 'entity'] },
	{ id: 'link_as', label: 'Link as', hint: 'occupies, owns…', match: ['link', 'link as', 'relation', 'relationship', 'role'] },
	{ id: 'tags', label: 'Tags', hint: 'separate with ;', match: ['tags', 'tag', 'category', 'categories', 'type', 'business type', 'trade', 'classification'] },
	{ id: 'names', label: 'Other names', hint: 'separate with ;', match: ['aka', 'also known as', 'other names', 'alias', 'aliases', 'dba', 'formerly'] },
	{ id: 'summary', label: 'Summary', match: ['summary', 'description', 'about', 'details'] },
	{ id: 'note', label: 'Note', hint: 'on the link', match: ['note', 'notes', 'comment', 'comments', 'remarks', 'source note'] },
	{ id: 'lat', label: 'Latitude', match: ['lat', 'latitude'] },
	{ id: 'lon', label: 'Longitude', match: ['lon', 'lng', 'long', 'longitude'] }
];

export const fieldLabel = (id: string, attrs: { id: string; label: string }[] = []) =>
	id.startsWith('attr:') ? `Fact: ${attrs.find((a) => a.id === id.slice(5))?.label ?? id.slice(5)}` : (TABLE_FIELDS.find((f) => f.id === id)?.label ?? 'Ignore');

const clean = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

/** The field a header most likely means ('' = ignore), never reusing one already taken. */
export function guessFields(headers: string[], attrs: { id: string; label: string }[] = []): string[] {
	const taken = new Set<string>();
	return headers.map((h) => {
		const c = clean(h);
		if (!c) return '';
		const exact = TABLE_FIELDS.find((f) => !taken.has(f.id) && (f.match.includes(c) || clean(f.label) === c));
		const attr = attrs.find((a) => !taken.has(`attr:${a.id}`) && (clean(a.label) === c || clean(a.id) === c));
		const loose = TABLE_FIELDS.find((f) => !taken.has(f.id) && f.match.some((m) => m.length > 3 && (c.startsWith(m + ' ') || c.endsWith(' ' + m))));
		const id = exact?.id ?? (attr ? `attr:${attr.id}` : loose?.id ?? '');
		if (id) taken.add(id);
		return id;
	});
}

/** Split a list cell: "Retail; Food & drink" or "Retail, Food" (semicolons win when present). */
export const splitList = (s: string | undefined | null) =>
	(s ?? '')
		.split(/;/.test(s ?? '') ? ';' : /\|/.test(s ?? '') ? '|' : ',')
		.map((x) => x.trim())
		.filter(Boolean);

/**
 * CSV (RFC 4180: quoted fields, doubled quotes, newlines inside quotes) or tab-separated text.
 * The delimiter is whichever of tab / ; / , the first line has most of, outside quotes.
 */
export function parseDelimited(text: string): string[][] {
	const t = text.replace(/^﻿/, '').replace(/\r\n?/g, '\n');
	const first = t.split('\n', 1)[0] ?? '';
	const count = (ch: string) => {
		let n = 0;
		let q = false;
		for (const c of first) {
			if (c === '"') q = !q;
			else if (c === ch && !q) n++;
		}
		return n;
	};
	const delim = ['\t', ';', ','].reduce((best, ch) => (count(ch) > count(best) ? ch : best), ',');
	const rows: string[][] = [];
	let row: string[] = [];
	let cell = '';
	let quoted = false;
	for (let i = 0; i < t.length; i++) {
		const c = t[i];
		if (quoted) {
			if (c === '"' && t[i + 1] === '"') {
				cell += '"';
				i++;
			} else if (c === '"') quoted = false;
			else cell += c;
		} else if (c === '"' && cell.trim() === '') {
			quoted = true;
			cell = '';
		} else if (c === delim) {
			row.push(cell.trim());
			cell = '';
		} else if (c === '\n') {
			row.push(cell.trim());
			rows.push(row);
			row = [];
			cell = '';
		} else cell += c;
	}
	if (cell !== '' || row.length) {
		row.push(cell.trim());
		rows.push(row);
	}
	return rows.filter((r) => r.some((c) => c !== ''));
}

/** A unit written into the address: "512 Broadway, Suite 3", "512 Broadway Rm. 201", "512 Broadway #3". */
export function unitFromAddress(address: string): { address: string; unit: string | null } {
	const m = address.match(/(?:,\s*|\s+)(?:suite|ste\.?|unit|room|rm\.?|apt\.?|office|#)\s*#?\s*([\w-]+)\s*$/i);
	if (!m) return { address: address.trim(), unit: null };
	return { address: address.slice(0, m.index).trim().replace(/,$/, ''), unit: m[1] };
}

export const TEMPLATE_CSV = [
	'Name,Address,Unit,Listed in,From,Until,Category,Other names,Note',
	'"Kresge\'s",512 Broadway,,1925,,,Retail,"S. S. Kresge Co.",City directory p. 214',
	'Joe\'s Diner,520 Broadway,2,1925,,,Food & drink,,',
	'Gary Hotel,600 Broadway,,,1927,1975,Lodging,Hotel Gary,'
].join('\n');

/** What the preview sends back for each row, and what can be changed before applying. */
export interface SheetRow {
	n: number;
	name: string;
	kind: string;
	address: string | null;
	unit: string | null;
	/** what the row says about when (shown) */
	when: string;
	link_as: string;
	/** a page with that name already */
	same: { id: string; slug: string; name: string } | null;
	similar: { id: string; slug: string; name: string; score: number } | null;
	place: { id: string; slug: string; name: string; kind: string } | null;
	place_how: 'named' | 'address' | 'address, other years' | 'geocoded' | null;
	space: { id: string; slug: string; name: string } | null;
	tags: { id: string; label: string }[];
	missing_tags: string[];
	lat: number | null;
	lon: number | null;
	issues: string[];
	/** the editor's choices */
	use_existing: string | null;
	place_id: string | null;
	point: boolean;
	include: boolean;
}

export interface SheetOptions {
	kind: string;
	year: string;
	link_as: string;
	/** '' for none */
	source_id: string;
	confidence: string;
	points: boolean;
	geocode: boolean;
	private: boolean;
	label: string | null;
}
