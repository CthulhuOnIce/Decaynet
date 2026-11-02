import { fail } from '@sveltejs/kit';
import { entityBySlug, requirePermission } from '$lib/server/db';
import { dbMessage } from '$lib/server/forms';
import type { TimelineFix } from '$lib/timelineCleanup';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals }) => {
	await requirePermission(locals, 'clean_timelines');
	const sb = locals.supabase;
	const entity = await entityBySlug(sb, params.slug);
	const [plan, states, geoms] = await Promise.all([
		sb.rpc('timeline_plan', { p_entity: entity.id }),
		sb.from('entity_states').select('id, status, valid_from, valid_from_precision, valid_to, valid_to_precision, note, lifecycle_statuses(label, color, sort)').eq('entity_id', entity.id).order('valid_from', { nullsFirst: true }),
		sb.from('entity_geometries').select('id, role, valid_from, valid_from_precision, valid_to, valid_to_precision').eq('entity_id', entity.id).order('valid_from', { nullsFirst: true })
	]);
	if (plan.error) throw new Error(plan.error.message);
	return {
		entity,
		fixes: (plan.data ?? []) as TimelineFix[],
		states: states.data ?? [],
		geoms: geoms.data ?? []
	};
};

export const actions: Actions = {
	apply: async ({ request, params, locals }) => {
		await requirePermission(locals, 'clean_timelines');
		const entity = await entityBySlug(locals.supabase, params.slug);
		const keys = (await request.formData()).getAll('key').map(String).filter(Boolean);
		if (!keys.length) return fail(400, { error: 'Tick at least one fix to apply.' });
		const { data, error } = await locals.supabase.rpc('normalize_timeline', { p_entity: entity.id, p_keys: keys });
		if (error) return fail(400, { error: dbMessage(error) });
		const r = data as { applied: number; remaining: number };
		return {
			ok: `Applied ${r.applied} fix${r.applied === 1 ? '' : 'es'}.${r.remaining ? ` ${r.remaining} still proposed.` : ' The timeline is tidy.'}`
		};
	}
};
