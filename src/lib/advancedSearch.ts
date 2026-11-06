/*
 * Advanced search: the filters, read from (and written to) the page's URL so a search is a
 * link you can share or come back to, and turned into the JSON advanced_search() takes.
 */

/** Properties a page can have or lack ("set" / "unset"). */
export const SEARCH_PROPS = [
	{ id: 'start', label: 'Start date' },
	{ id: 'end', label: 'End date' },
	{ id: 'shape', label: 'Shape on the map' },
	{ id: 'address', label: 'Address' },
	{ id: 'condition', label: 'Condition' },
	{ id: 'names', label: 'Other names' },
	{ id: 'sources', label: 'Citations' },
	{ id: 'article', label: 'Article (60+ words)' },
	{ id: 'photos', label: 'Photos' },
	{ id: 'tags', label: 'Tags' },
	{ id: 'links', label: 'Links to other pages' }
] as const;
export type SearchProp = (typeof SEARCH_PROPS)[number]['id'];

export const SEARCH_IN = [
	{ id: 'names', label: 'Names (every name it had)' },
	{ id: 'addresses', label: 'Addresses' },
	{ id: 'summary', label: 'Summaries' },
	{ id: 'article', label: 'Article text' }
] as const;

export const MATCH_MODES = [
	{ id: 'fuzzy', label: 'Fuzzy (close spellings, parts of words)' },
	{ id: 'contains', label: 'Contains' },
	{ id: 'starts', label: 'Starts with' },
	{ id: 'exact', label: 'Exactly' }
] as const;

export const SORTS = [
	{ id: 'relevance', label: 'Best match' },
	{ id: 'name', label: 'Name' },
	{ id: 'start', label: 'Oldest first' },
	{ id: 'end', label: 'Gone first' },
	{ id: 'updated', label: 'Recently edited' }
] as const;

/** How many years before the map's year the map's own search looks. */
export const TIME_WINDOW = 5;

export interface FactFilter {
	key: string;
	min: string;
	max: string;
	text: string;
	unset: boolean;
}

export interface SearchParams {
	q: string;
	match: string;
	in: string[];
	kinds: string[];
	from: string;
	to: string;
	sfrom: string;
	sto: string;
	efrom: string;
	eto: string;
	statuses: string[];
	statusNone: boolean;
	statusYear: string;
	tags: string[];
	articleStatuses: string[];
	confidences: string[];
	props: Partial<Record<SearchProp, 'set' | 'unset'>>;
	facts: FactFilter[];
	street: string;
	nfrom: string;
	nto: string;
	sort: string;
	page: number;
}

export const PER_PAGE = 50;
const year = (v: string | null) => (v && /^\d{1,4}$/.test(v.trim()) ? v.trim() : '');
const num = (v: string | null) => (v && /^-?\d+(\.\d+)?$/.test(v.trim()) ? v.trim() : '');

export function readParams(u: URLSearchParams): SearchParams {
	const all = (k: string) => u.getAll(k).filter(Boolean);
	const props: SearchParams['props'] = {};
	for (const p of SEARCH_PROPS) {
		const v = u.get(`has_${p.id}`);
		if (v === 'set' || v === 'unset') props[p.id] = v;
	}
	const facts: FactFilter[] = [1, 2].map((i) => ({
		key: u.get(`fact${i}`) ?? '',
		min: num(u.get(`fact${i}_min`)),
		max: num(u.get(`fact${i}_max`)),
		text: (u.get(`fact${i}_text`) ?? '').trim(),
		unset: u.get(`fact${i}_unset`) === '1'
	}));
	return {
		q: (u.get('q') ?? '').trim(),
		match: u.get('match') ?? 'fuzzy',
		in: all('in').length ? all('in') : ['names'],
		kinds: all('kind'),
		from: year(u.get('from')),
		to: year(u.get('to')),
		sfrom: year(u.get('sfrom')),
		sto: year(u.get('sto')),
		efrom: year(u.get('efrom')),
		eto: year(u.get('eto')),
		statuses: all('status'),
		statusNone: u.get('status_none') === '1',
		statusYear: year(u.get('status_year')),
		tags: all('tag'),
		articleStatuses: all('astatus'),
		confidences: all('conf'),
		props,
		facts,
		street: (u.get('street') ?? '').trim(),
		nfrom: num(u.get('nfrom')),
		nto: num(u.get('nto')),
		sort: u.get('sort') ?? 'relevance',
		page: Math.max(1, Number(u.get('page')) || 1)
	};
}

/** Anything asked for beyond the defaults? (An empty form searches nothing.) */
export function isSearch(p: SearchParams) {
	return !!(
		p.q || p.kinds.length || p.from || p.to || p.sfrom || p.sto || p.efrom || p.eto || p.statuses.length || p.statusNone ||
		p.tags.length || p.articleStatuses.length || p.confidences.length || Object.keys(p.props).length ||
		p.facts.some((f) => f.key) || p.street || p.nfrom || p.nto
	);
}

/** The JSON advanced_search() takes. */
export function toQuery(p: SearchParams) {
	const n = (v: string) => (v === '' ? undefined : Number(v));
	return {
		q: p.q || undefined,
		match: p.match,
		in: p.in,
		kinds: p.kinds.length ? p.kinds : undefined,
		from_year: n(p.from),
		to_year: n(p.to),
		started: p.sfrom || p.sto ? { from: n(p.sfrom), to: n(p.sto) } : undefined,
		ended: p.efrom || p.eto ? { from: n(p.efrom), to: n(p.eto) } : undefined,
		statuses: p.statuses.length ? p.statuses : undefined,
		status_none: p.statusNone || undefined,
		status_year: n(p.statusYear),
		tags: p.tags.length ? p.tags : undefined,
		article_statuses: p.articleStatuses.length ? p.articleStatuses : undefined,
		confidences: p.confidences.length ? p.confidences : undefined,
		props: p.props,
		facts: p.facts.filter((f) => f.key).map((f) => ({ key: f.key, min: n(f.min), max: n(f.max), text: f.text || undefined, unset: f.unset || undefined })),
		street: p.street || undefined,
		number_from: n(p.nfrom),
		number_to: n(p.nto),
		sort: p.sort,
		limit: PER_PAGE,
		offset: (p.page - 1) * PER_PAGE
	};
}

/** One result row, as advanced_search() returns it. */
export interface SearchResult {
	id: string;
	slug: string;
	kind: string;
	name: string;
	name_then: string | null;
	matched: string | null;
	matched_in: string | null;
	exists_from: string | null;
	exists_from_precision: string;
	exists_to: string | null;
	exists_to_precision: string;
	status: string | null;
	status_label: string | null;
	status_color: string | null;
	article_status: string | null;
	address: string | null;
	lon: number | null;
	lat: number | null;
	score: number;
	total: number;
}
