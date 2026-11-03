import type { SupabaseClient } from '@supabase/supabase-js';
import { NEW_SOURCE, SOURCE_KINDS, SOURCE_OPTION_COLUMNS, type SourceOption } from '$lib/sources';
import { parseFuzzyDate } from '$lib/time';
import { queueArchive } from './archive';
import { FormError, dbMessage, str } from './forms';

/** Sources a page's forms can cite: its own page sources first, then the shared library. */
export async function sourceOptions(sb: SupabaseClient, entityId: string | null): Promise<SourceOption[]> {
	const q = sb.from('sources').select(SOURCE_OPTION_COLUMNS);
	const { data } = await (entityId ? q.or(`entity_id.is.null,entity_id.eq.${entityId}`) : q.is('entity_id', null)).order('title');
	return (data ?? []) as SourceOption[];
}

/** Library sources only (forms that aren't about one page). */
export const librarySources = (sb: SupabaseClient) => sourceOptions(sb, null);

/** Read the short "new source" fields (<SourceFields prefix=…>) into a sources row. */
export function sourceFromForm(fd: FormData, prefix = 'ns_') {
	const title = str(fd, `${prefix}title`);
	if (!title) throw new FormError('Give the new source a title.');
	const kind = str(fd, `${prefix}kind`) ?? 'other';
	const published = parseFuzzyDate(str(fd, `${prefix}published_on`));
	const url = str(fd, `${prefix}url`);
	if (url && !/^https?:\/\//i.test(url)) throw new FormError('The source URL should start with http:// or https://');
	return {
		title: title.replace(/\s+/g, ' ').slice(0, 300),
		kind: (SOURCE_KINDS as readonly string[]).includes(kind) ? kind : 'other',
		author: str(fd, `${prefix}author`),
		publisher: str(fd, `${prefix}publisher`),
		published_on: published?.date ?? null,
		published_precision: published?.precision ?? 'year',
		url
	};
}

/** A source made from the "new source" fields; `reused` = an identical one already existed. */
export type MadeSource = SourceOption & { reused?: boolean };

const norm = (v: string | null | undefined) => (v ?? '').trim().replace(/\s+/g, ' ').toLowerCase();

/**
 * Create a source that belongs to one page, or reuse an identical one: the same title, link,
 * kind, author, publisher and date, already on this page or in the library. Saving a form
 * twice (the workbench and fact edits keep their fields after saving) or citing the same
 * thing again no longer makes copies.
 */
export async function createPageSource(sb: SupabaseClient, fd: FormData, entityId: string, prefix = 'ns_'): Promise<MadeSource> {
	const row = sourceFromForm(fd, prefix);
	const like = row.title.replace(/[\\%_]/g, (c) => `\\${c}`);
	const { data: near } = await sb
		.from('sources')
		.select(SOURCE_OPTION_COLUMNS)
		.or(`entity_id.eq.${entityId},entity_id.is.null`)
		.ilike('title', like)
		.limit(20);
	const same = ((near ?? []) as SourceOption[])
		.filter(
			(s) =>
				norm(s.title) === norm(row.title) &&
				norm(s.url) === norm(row.url) &&
				(s.kind ?? 'other') === row.kind &&
				norm(s.author) === norm(row.author) &&
				norm(s.publisher) === norm(row.publisher) &&
				(s.published_on ?? null) === row.published_on
		)
		.sort((a, b) => Number(!a.entity_id) - Number(!b.entity_id))[0]; // this page's own first
	if (same) return { ...same, reused: true };

	const { data, error } = await sb.from('sources').insert({ ...row, entity_id: entityId }).select(SOURCE_OPTION_COLUMNS).single();
	if (error) throw new FormError(dbMessage(error));
	if (row.url) queueArchive(data.id, sb);
	return data as SourceOption;
}

/**
 * If a fact form chose "New source…", create it for this page (or reuse an identical one)
 * and point the form's source_id at it. Returns it, or null when an existing source was picked.
 */
export async function resolveInlineSource(sb: SupabaseClient, fd: FormData, entityId: string): Promise<MadeSource | null> {
	if (fd.get('source_id') !== NEW_SOURCE) return null;
	const s = await createPageSource(sb, fd, entityId);
	fd.set('source_id', s.id);
	return s;
}

/** Undo resolveInlineSource after the fact itself couldn't be saved (only a source it created). */
export async function discardSource(sb: SupabaseClient, s: MadeSource | null) {
	if (s && !s.reused) await sb.from('sources').delete().eq('id', s.id);
}

/** What a form action hands back so the form can switch from "New source…" to the source it made. */
export const madeSource = (s: MadeSource | null): SourceOption | undefined => {
	if (!s) return undefined;
	const { reused: _reused, ...option } = s;
	return option;
};
