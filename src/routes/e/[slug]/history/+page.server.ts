import { entityBySlug } from '$lib/server/db';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals }) => {
	const sb = locals.supabase;
	const entity = await entityBySlug(sb, params.slug);
	const [revisions, changes, statusEvents] = await Promise.all([
		sb.from('article_revisions').select('*, author:profiles(display_name)').eq('entity_id', entity.id).order('created_at', { ascending: false }).limit(100),
		sb.from('change_log').select('*').eq('entity_id', entity.id).order('created_at', { ascending: false }).limit(200),
		sb.from('article_status_events').select('*, actor:profiles(display_name)').eq('entity_id', entity.id).order('created_at', { ascending: false })
	]);
	const actorIds = [...new Set((changes.data ?? []).map((c) => c.actor_id).filter(Boolean))];
	const { data: actors } = actorIds.length
		? await sb.from('profiles').select('id, display_name').in('id', actorIds)
		: { data: [] };
	return {
		entity,
		revisions: revisions.data ?? [],
		changes: changes.data ?? [],
		statusEvents: statusEvents.data ?? [],
		actors: Object.fromEntries((actors ?? []).map((a) => [a.id, a.display_name])) as Record<string, string>
	};
};
