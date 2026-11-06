/*
 * Admin › Records: the columns a grid can show, the context a change set works under, and
 * the grid's state in the URL (filters are advanced search's own parameters, so a search can
 * be opened in Records as it is).
 */
import { readParams, toQuery, type SearchParams } from '$lib/advancedSearch';
import type { Vocabulary } from '$lib/types';

export type WriteMode = 'seen' | 'starting' | 'only' | 'correct';
export type ConflictRule = 'skip' | 'trim' | 'dispute';

export const MODES: { id: WriteMode; label: string; hint: string }[] = [
	{ id: 'seen', label: 'Seen in', hint: 'A snapshot (a map, a directory, a photo): it was so then. Joins up with the same value either side.' },
	{ id: 'starting', label: 'Starting', hint: 'A change: what was there ends, this runs up to the next recorded change.' },
	{ id: 'only', label: 'Only', hint: 'Exactly these years; what overlaps is trimmed or split around them.' },
	{ id: 'correct', label: 'Correction', hint: 'Fix the record in force then (a typo, a wrong entry); no new history, no source needed.' }
];

export const CONFLICTS: { id: ConflictRule; label: string }[] = [
	{ id: 'skip', label: 'Leave it and skip the row' },
	{ id: 'dispute', label: 'Add mine alongside, marked disputed' },
	{ id: 'trim', label: 'Cut it back anyway' }
];

export interface RecordsContext {
	at: string | null;
	at_p: string;
	to: string | null;
	to_p: string;
	mode: WriteMode;
	source_id: string | null;
	source_detail: string | null;
	confidence: string;
	conflict: ConflictRule;
}

export const CONTEXT_DEFAULTS: RecordsContext = {
	at: null,
	at_p: 'year',
	to: null,
	to_p: 'year',
	mode: 'seen',
	source_id: null,
	source_detail: null,
	confidence: 'probable',
	conflict: 'skip'
};

export interface ChangeSet {
	id: string;
	title: string;
	context: Partial<RecordsContext>;
	created_at: string;
	updated_at: string;
	undone_at: string | null;
	progress: Record<string, unknown>;
	changes?: number;
	pages?: number;
}

/** A column: a field records_write can set, or something about the page itself. */
export interface Column {
	id: string;
	label: string;
	/** fact: dated rows (records_write); page: the page itself (records_set_pages); info: read only */
	type: 'fact' | 'page' | 'info';
	/** several at once (tags, tenants) */
	multi?: boolean;
	/** what the editor offers */
	input: 'text' | 'number' | 'status' | 'address' | 'tag' | 'entity' | 'span' | 'none';
	/** for entity columns: which kinds the other end can be */
	kinds?: string[] | null;
	unit?: string | null;
	short?: string;
}

export const PAGE_COLUMNS: Column[] = [
	{ id: 'name', label: 'Name then', type: 'fact', input: 'text', short: 'Name' },
	{ id: 'status', label: 'Condition', type: 'fact', input: 'status' },
	{ id: 'address', label: 'Address', type: 'fact', input: 'address' },
	{ id: 'tag', label: 'Tags', type: 'fact', multi: true, input: 'tag' },
	{ id: 'lifespan', label: 'Lifespan', type: 'page', input: 'span' },
	{ id: 'parent', label: 'Inside', type: 'info', input: 'none' },
	{ id: 'spaces', label: 'Spaces', type: 'info', input: 'none' },
	{ id: 'shape', label: 'Shape then', type: 'info', input: 'none', short: 'Shape' },
	{ id: 'summary', label: 'Summary', type: 'page', input: 'text' }
];

/** Every column the vocabulary allows: the page's own, each fact, each link both ways. */
export function allColumns(v: Vocabulary): Column[] {
	const facts: Column[] = v.attributeKeys.map((k) => ({
		id: `attr:${k.id}`,
		label: k.label.charAt(0).toUpperCase() + k.label.slice(1),
		type: 'fact',
		input: k.value_type === 'number' || k.value_type === 'year' ? 'number' : 'text',
		unit: k.unit
	}));
	const links: Column[] = v.relationTypes
		.filter((r) => r.id !== 'part_of')
		.flatMap((r) => [
			{ id: `rel:${r.id}:in`, label: cap(r.inverse_label), type: 'fact', multi: true, input: 'entity', kinds: r.subject_kinds } as Column,
			{ id: `rel:${r.id}:out`, label: cap(r.label), type: 'fact', multi: true, input: 'entity', kinds: r.object_kinds } as Column
		]);
	// the two everyone wants under plain names
	for (const l of links) {
		if (l.id === 'rel:occupies:in') l.label = 'Tenants';
		if (l.id === 'rel:occupies:out') l.label = 'Occupies';
	}
	return [...PAGE_COLUMNS, ...facts, ...links];
}

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** Columns to start with, by what's listed. */
export function defaultColumns(kinds: string[]): string[] {
	const only = (k: string) => kinds.length === 1 && kinds[0] === k;
	if (only('space')) return ['name', 'parent', 'rel:occupies:in', 'address', 'tag'];
	if (only('organization') || only('person')) return ['name', 'rel:occupies:out', 'tag', 'lifespan'];
	if (only('street')) return ['name', 'lifespan'];
	return ['name', 'status', 'address', 'rel:occupies:in', 'tag', 'spaces'];
}

export const SORTS = [
	{ id: 'name', label: 'Name' },
	{ id: 'address', label: 'Address then' },
	{ id: 'tree', label: 'Buildings, then their spaces' },
	{ id: 'west', label: 'West → east' },
	{ id: 'east', label: 'East → west' },
	{ id: 'north', label: 'North → south' },
	{ id: 'south', label: 'South → north' },
	{ id: 'start', label: 'Oldest first' },
	{ id: 'updated', label: 'Recently edited' },
	{ id: 'relevance', label: 'Best match' }
] as const;

export const PER_PAGE = [100, 250, 500];

export interface GridParams {
	search: SearchParams;
	ids: string[];
	inside: string;
	cols: string[];
	sort: string;
	page: number;
	per: number;
	/** the year to look at when no change set is open */
	year: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function readGrid(u: URLSearchParams): GridParams {
	const search = readParams(u);
	const ids = (u.get('ids') ?? '').split(',').filter((s) => UUID.test(s)).slice(0, 1000);
	const per = Number(u.get('per'));
	const cols = (u.get('cols') ?? '').split(',').filter(Boolean);
	return {
		search,
		ids,
		inside: UUID.test(u.get('inside') ?? '') ? (u.get('inside') as string) : '',
		cols: cols.length ? cols : defaultColumns(search.kinds),
		sort: SORTS.some((s) => s.id === u.get('sort')) ? (u.get('sort') as string) : 'name',
		page: Math.max(1, Number(u.get('page')) || 1),
		per: PER_PAGE.includes(per) ? per : 100,
		year: /^\d{3,4}$/.test(u.get('y') ?? '') ? (u.get('y') as string) : ''
	};
}

/** The JSON records_grid() takes. */
export function gridQuery(g: GridParams, at: string) {
	const q = toQuery({ ...g.search, sort: 'name', page: 1 }) as Record<string, unknown>;
	delete q.limit;
	delete q.offset;
	delete q.sort;
	return {
		...q,
		ids: g.ids.length ? g.ids : undefined,
		inside: g.inside || undefined,
		// conditions filter on the year you're working in
		status_year: g.search.statusYear ? Number(g.search.statusYear) : Number(at.slice(0, 4)),
		at,
		fields: g.cols.filter((c) => !['lifespan', 'parent', 'spaces', 'shape', 'summary'].includes(c)),
		sort: g.sort,
		limit: g.per,
		offset: (g.page - 1) * g.per
	};
}

/** One fact row in a cell, as records_grid() returns it. */
export interface CellFact {
	id: string;
	v: unknown;
	label: string;
	f: string | null;
	fp: string;
	t: string | null;
	tp: string;
	span: string;
	src: string | null;
	src_title: string | null;
	detail: string | null;
	conf: string;
}

export interface GridRow {
	id: string;
	slug: string;
	kind: string;
	name: string;
	name_then: string;
	summary: string | null;
	private: boolean;
	from: string | null;
	from_p: string;
	to: string | null;
	to_p: string;
	span: string;
	there: boolean;
	parent: { id: string; slug: string; name: string } | null;
	spaces: number;
	depth: number;
	side: string | null;
	shape: boolean;
	cells: Record<string, CellFact[]>;
}

/** An item for records_write(). */
export interface WriteItem {
	entity: string;
	field: string;
	op?: 'set' | 'add' | 'remove';
	value?: unknown;
	mode?: WriteMode;
	at?: string;
	at_p?: string;
	to?: string | null;
	to_p?: string;
	source_id?: string | null;
	source_detail?: string | null;
	confidence?: string;
	conflict?: ConflictRule;
	note?: string;
}

export interface WriteResult {
	entity: string;
	field: string;
	op: string;
	name?: string;
	slug?: string;
	value_label?: string;
	when?: string;
	outcome: 'changed' | 'cited' | 'already' | 'skipped' | 'conflict';
	reason?: string;
	steps?: string[];
}

export interface WriteSummary {
	items: WriteResult[];
	after: number | null;
	changed: number;
	cited: number;
	already: number;
	skipped: number;
	conflict: number;
}

/** "1925" for a year-precision date, as the context bar shows it. */
export const yearLabel = (d: string | null | undefined) => (d ? String(Number(d.slice(0, 4))) : '');

/** A house-number series: start, step, and (with sides) odd numbers on one side, even on the other. */
export function numberSeries(count: number, start: number, step: number): number[] {
	return Array.from({ length: count }, (_, i) => start + i * step);
}

/** A change_log row, as a change set's review shows it. */
export interface LogRow {
	id: number;
	table_name: string;
	op: 'INSERT' | 'UPDATE' | 'DELETE';
	row_id: string | null;
	entity_id: string | null;
	old_data: Record<string, unknown> | null;
	new_data: Record<string, unknown> | null;
	created_at: string;
}

export const TABLE_LABELS: Record<string, string> = {
	entities: 'Page',
	entity_names: 'Name',
	entity_states: 'Condition',
	addresses: 'Address',
	entity_attributes: 'Fact',
	entity_tags: 'Tag',
	relations: 'Link',
	entity_geometries: 'Shape',
	event_details: 'Event',
	media_items: 'Media'
};

/** Fields not worth showing in a diff. */
const QUIET = new Set(['id', 'created_at', 'created_by', 'updated_at', 'entity_id', 'geom', 'lifespan', 'valid', 'published_at', 'updated_by']);

/** The fields an UPDATE changed: [field, before, after]. */
export function changedFields(r: LogRow): [string, unknown, unknown][] {
	const o = r.old_data ?? {};
	const n = r.new_data ?? {};
	const keys = [...new Set([...Object.keys(o), ...Object.keys(n)])].filter((k) => !QUIET.has(k));
	const out = keys.filter((k) => JSON.stringify(o[k] ?? null) !== JSON.stringify(n[k] ?? null)).map((k) => [k, o[k], n[k]] as [string, unknown, unknown]);
	if (r.table_name === 'entity_geometries' && JSON.stringify(o.geom) !== JSON.stringify(n.geom)) out.push(['shape', 'moved or redrawn', '']);
	return out;
}

export const FIELD_LABELS: Record<string, string> = {
	valid_from: 'from',
	valid_from_precision: 'from precision',
	valid_to: 'until',
	valid_to_precision: 'until precision',
	source_id: 'source',
	source_detail: 'where in the source',
	house_number: 'number',
	street_id: 'street',
	tag_id: 'tag',
	subject_id: 'from page',
	object_id: 'to page',
	exists_from: 'starts',
	exists_to: 'ends',
	is_private: 'private'
};
