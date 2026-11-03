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
		title: title.slice(0, 300),
		kind: (SOURCE_KINDS as readonly string[]).includes(kind) ? kind : 'other',
		author: str(fd, `${prefix}author`),
		publisher: str(fd, `${prefix}publisher`),
		published_on: published?.date ?? null,
		published_precision: published?.precision ?? 'year',
		url
	};
}

/** Create a source that belongs to one page. */
export async function createPageSource(sb: SupabaseClient, fd: FormData, entityId: string, prefix = 'ns_'): Promise<SourceOption> {
	const row = sourceFromForm(fd, prefix);
	const { data, error } = await sb.from('sources').insert({ ...row, entity_id: entityId }).select(SOURCE_OPTION_COLUMNS).single();
	if (error) throw new FormError(dbMessage(error));
	if (row.url) queueArchive(data.id, sb);
	return data as SourceOption;
}

/**
 * If a fact form chose "New source…", create it for this page and point the
 * form's source_id at it. Returns the new source's id (so a failed save can
 * remove it again), or null when an existing source was picked.
 */
export async function resolveInlineSource(sb: SupabaseClient, fd: FormData, entityId: string): Promise<string | null> {
	if (fd.get('source_id') !== NEW_SOURCE) return null;
	const s = await createPageSource(sb, fd, entityId);
	fd.set('source_id', s.id);
	return s.id;
}

/** Undo resolveInlineSource after the fact itself couldn't be saved. */
export async function discardSource(sb: SupabaseClient, id: string | null) {
	if (id) await sb.from('sources').delete().eq('id', id);
}
