import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals }) => {
	if (!/^[0-9a-f-]{36}$/i.test(params.id)) error(404, 'Not found');
	const sb = locals.supabase;
	const { data: person } = await sb.from('profiles').select('id, display_name, bio, website, role, created_at').eq('id', params.id).maybeSingle();
	if (!person) error(404, 'No such contributor');
	const { data: activity } = await sb.from('recent_activity').select('*').eq('actor_id', params.id).order('created_at', { ascending: false }).limit(100);
	const ids = [...new Set((activity ?? []).map((a) => a.entity_id).filter(Boolean))];
	const { data: ents } = ids.length ? await sb.from('entities').select('id, slug, name').in('id', ids) : { data: [] };
	return {
		person,
		activity: activity ?? [],
		entities: Object.fromEntries((ents ?? []).map((e) => [e.id, e])) as Record<string, { slug: string; name: string }>
	};
};
