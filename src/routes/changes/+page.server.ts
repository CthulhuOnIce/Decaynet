import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, url }) => {
	const sb = locals.supabase;
	const filter = url.searchParams.get('only');
	let q = sb.from('recent_activity').select('*').order('created_at', { ascending: false }).limit(150);
	if (filter === 'prose') q = q.in('activity', ['revision', 'status']);
	if (filter === 'facts') q = q.eq('activity', 'fact');
	const { data, error } = await q;
	const rows = data ?? [];

	const entityIds = [...new Set(rows.map((r) => r.entity_id).filter(Boolean))];
	const actorIds = [...new Set(rows.map((r) => r.actor_id).filter(Boolean))];
	const [ents, actors] = await Promise.all([
		entityIds.length ? sb.from('entities').select('id, slug, name, kind').in('id', entityIds) : { data: [] },
		actorIds.length ? sb.from('profiles').select('id, display_name').in('id', actorIds) : { data: [] }
	]);
	return {
		filter,
		rows,
		error: error?.message ?? null,
		entities: Object.fromEntries((ents.data ?? []).map((e) => [e.id, e])),
		actors: Object.fromEntries((actors.data ?? []).map((a) => [a.id, a.display_name])) as Record<string, string>
	};
};
