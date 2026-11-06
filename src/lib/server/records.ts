import type { SupabaseClient } from '@supabase/supabase-js';
import type { LogRow } from '$lib/records';

/** Admin › Records: the change set this admin has open (a cookie on /admin/records). */
export const SET_COOKIE = 'dn_records_set';
export const SET_COOKIE_OPTS = { path: '/admin/records', httpOnly: true, sameSite: 'lax' as const, maxAge: 60 * 60 * 24 * 60 };


/** Names for the pages, sources and tags a list of changes mentions. */
export async function logNames(sb: SupabaseClient, rows: LogRow[]) {
	const ids = new Set<string>();
	const srcIds = new Set<string>();
	const tagIds = new Set<string>();
	for (const r of rows) {
		for (const d of [r.old_data, r.new_data]) {
			if (!d) continue;
			for (const k of ['entity_id', 'subject_id', 'object_id', 'street_id']) if (typeof d[k] === 'string') ids.add(d[k] as string);
			if (typeof d.source_id === 'string') srcIds.add(d.source_id);
			if (typeof d.tag_id === 'string') tagIds.add(d.tag_id);
		}
		if (r.entity_id) ids.add(r.entity_id);
	}
	const none = Promise.resolve({ data: [] as never[] });
	const [ents, srcs, tags] = await Promise.all([
		ids.size ? sb.from('entities').select('id, name, slug, kind').in('id', [...ids]) : none,
		srcIds.size ? sb.from('sources').select('id, title').in('id', [...srcIds]) : none,
		tagIds.size ? sb.from('tags').select('id, label').in('id', [...tagIds]) : none
	]);
	return {
		names: Object.fromEntries(((ents.data ?? []) as { id: string; name: string; slug: string; kind: string }[]).map((e) => [e.id, e])),
		sources: Object.fromEntries(((srcs.data ?? []) as { id: string; title: string }[]).map((s) => [s.id, s.title])),
		tags: Object.fromEntries(((tags.data ?? []) as { id: string; label: string }[]).map((t) => [t.id, t.label]))
	};
}
