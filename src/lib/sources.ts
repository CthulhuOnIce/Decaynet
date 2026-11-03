/** Shared between server and client: source kinds and the source picker's shape. */

export const SOURCE_KINDS = [
	'book', 'newspaper', 'periodical', 'website', 'archive', 'map', 'photograph',
	'public_record', 'oral_history', 'directory', 'film', 'other'
] as const;
export type SourceKind = (typeof SOURCE_KINDS)[number];

/** Picker value meaning "create a new source for this page from the fields below". */
export const NEW_SOURCE = '__new';

export interface SourceOption {
	id: string;
	title: string;
	/** page the source belongs to; null = shared library */
	entity_id: string | null;
	/** shown and searched in the source picker */
	kind?: string | null;
	author?: string | null;
	publisher?: string | null;
	published_on?: string | null;
	published_precision?: import('./types').Precision | null;
	url?: string | null;
}

/** Columns the source picker needs. */
export const SOURCE_OPTION_COLUMNS = 'id, title, entity_id, kind, author, publisher, published_on, published_precision, url';

/** [cite:<source id>] or [cite:<source id>|p. 42] in article markdown */
export const CITE = /\[cite:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\|([^\]\n]*))?\]/gi;

export const citeToken = (id: string, detail?: string | null) => {
	const d = (detail ?? '').replace(/[\]\n|]/g, ' ').trim();
	return d ? `[cite:${id}|${d}]` : `[cite:${id}]`;
};

/** Source ids cited in a body of markdown, in order of first appearance. */
export function extractCitations(md: string): string[] {
	return [...new Set([...md.matchAll(CITE)].map((m) => m[1].toLowerCase()))];
}
