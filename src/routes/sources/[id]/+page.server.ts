import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals }) => {
	if (!/^[0-9a-f-]{36}$/i.test(params.id)) error(404, 'Not found');
	const sb = locals.supabase;
	const [{ data: source }, { data: facts }, { data: media }] = await Promise.all([
		sb.from('sources').select('*').eq('id', params.id).maybeSingle(),
		sb.from('facts').select('*').eq('source_id', params.id).order('valid_from', { nullsFirst: false }).limit(500),
		sb.from('media_items').select('entity_id, media_type').eq('source_id', params.id)
	]);
	if (!source) error(404, 'Source not found');
	const ids = [...new Set([...(facts ?? []).flatMap((f) => [f.entity_id, f.other_id]), ...(media ?? []).map((m) => m.entity_id)].filter(Boolean))];
	const { data: ents } = ids.length ? await sb.from('entities').select('id, slug, name').in('id', ids) : { data: [] };
	return {
		source,
		facts: facts ?? [],
		media: media ?? [],
		entities: Object.fromEntries((ents ?? []).map((e) => [e.id, e])) as Record<string, { id: string; slug: string; name: string }>
	};
};
