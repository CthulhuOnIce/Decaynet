import { error, fail } from '@sveltejs/kit';
import { archiveSource } from '$lib/server/archive';
import { serviceClient } from '$lib/server/admin';
import { requireEditor } from '$lib/server/db';
import { dbMessage } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals }) => {
	if (!/^[0-9a-f-]{36}$/i.test(params.id)) error(404, 'Not found');
	const sb = locals.supabase;
	const [{ data: source }, { data: facts }, { data: media }, { data: articles }] = await Promise.all([
		sb.from('sources').select('*').eq('id', params.id).maybeSingle(),
		sb.from('facts').select('*').eq('source_id', params.id).order('valid_from', { nullsFirst: false }).limit(500),
		sb.from('media_items').select('entity_id, media_type').eq('source_id', params.id),
		sb.from('articles').select('entity_id').ilike('body', `%[cite:${params.id.toLowerCase()}%`).limit(200)
	]);
	if (!source) error(404, 'Source not found');
	const ids = [
		...new Set(
			[...(facts ?? []).flatMap((f) => [f.entity_id, f.other_id]), ...(media ?? []).map((m) => m.entity_id), ...(articles ?? []).map((a) => a.entity_id), source.entity_id].filter(Boolean)
		)
	];
	const { data: ents } = ids.length ? await sb.from('entities').select('id, slug, name').in('id', ids) : { data: [] };
	return {
		source,
		facts: facts ?? [],
		media: media ?? [],
		articles: (articles ?? []).map((a) => a.entity_id as string),
		entities: Object.fromEntries((ents ?? []).map((e) => [e.id, e])) as Record<string, { id: string; slug: string; name: string }>
	};
};

export const actions: Actions = {
	/** Share a page's own source with every page (it then shows in the /sources library and all pickers). */
	addToLibrary: async ({ params, locals }) => {
		await requireEditor(locals);
		const { error: err } = await locals.supabase.from('sources').update({ entity_id: null }).eq('id', params.id);
		if (err) return fail(400, { error: dbMessage(err) });
		return { ok: 'Added to the library.' };
	},
	/** Archive the link now (or again, after a failure). Waits for the result, which can take a minute. */
	archive: async ({ params, locals }) => {
		await requireEditor(locals);
		const sb = serviceClient() ?? locals.supabase;
		const result = await archiveSource(sb, params.id);
		if (result === 'archived') return { ok: 'Saved to the Internet Archive.' };
		const { data } = await sb.from('sources').select('archive_error').eq('id', params.id).maybeSingle();
		return fail(400, { error: data?.archive_error ?? "This source's link can't be archived (archiving may be turned off)." });
	}
};
