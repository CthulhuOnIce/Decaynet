import { fail } from '@sveltejs/kit';
import { entityBySlug, requirePermission } from '$lib/server/db';
import { dbMessage } from '$lib/server/forms';
import { dbFailure, isMissingFunction } from '$lib/server/schema';
import type { TimelineFix } from '$lib/timelineCleanup';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals }) => {
	await requirePermission(locals, 'clean_timelines');
	const sb = locals.supabase;
	const entity = await entityBySlug(sb, params.slug);
	const [plan, ignored, states, geoms, addresses] = await Promise.all([
		sb.rpc('timeline_plan', { p_entity: entity.id }),
		// items ignored while the timeline is as it is now (none on a database before migration 0032)
		sb.rpc('timeline_dismissed_keys', { p_entity: entity.id }),
		sb.from('entity_states').select('id, status, valid_from, valid_from_precision, valid_to, valid_to_precision, note, lifecycle_statuses(label, color, sort)').eq('entity_id', entity.id).order('valid_from', { nullsFirst: true }),
		sb.from('entity_geometries').select('id, role, valid_from, valid_from_precision, valid_to, valid_to_precision').eq('entity_id', entity.id).neq('role', 'viewpoint').order('valid_from', { nullsFirst: true }),
		sb.from('addresses').select('id, house_number, unit, raw_address, valid_from, valid_from_precision, valid_to, valid_to_precision, street:entities!addresses_street_id_fkey(name)').eq('entity_id', entity.id).order('valid_from', { nullsFirst: true })
	]);
	if (plan.error) dbFailure(plan.error, 'Timeline cleanup');
	return {
		entity,
		fixes: (plan.data ?? []) as TimelineFix[],
		ignored: (ignored.error ? [] : (ignored.data ?? [])) as string[],
		states: states.data ?? [],
		geoms: geoms.data ?? [],
		addresses: (addresses.data ?? []).map((a) => {
			const street = (a.street as unknown as { name: string } | null)?.name;
			return { ...a, label: (street ? [a.house_number, street, a.unit].filter(Boolean).join(' ') : a.raw_address) || a.house_number || 'address' };
		})
	};
};

const keysFrom = (fd: FormData, field: string) => fd.getAll(field).map(String).filter(Boolean);
const missing = 'The database is behind this version of the app: an admin has to run the migrate step.';

export const actions: Actions = {
	/** Ignore fixes, suggestions or notes until this page's timeline changes ("Ignore" on one, or the ticked ones). */
	dismiss: async ({ request, params, locals }) => {
		await requirePermission(locals, 'clean_timelines');
		const entity = await entityBySlug(locals.supabase, params.slug);
		const fd = await request.formData();
		const keys = keysFrom(fd, 'dismiss').length ? keysFrom(fd, 'dismiss') : keysFrom(fd, 'key');
		if (!keys.length) return fail(400, { error: 'Tick the items to ignore.' });
		const { error } = await locals.supabase.rpc('dismiss_timeline_items', { p_entity: entity.id, p_keys: keys });
		if (error) return fail(isMissingFunction(error) ? 503 : 400, { error: isMissingFunction(error) ? missing : dbMessage(error) });
		return { ok: `Ignored ${keys.length === 1 ? 'it' : `${keys.length} items`} until this page's timeline changes.` };
	},
	/** Bring ignored items back (one, or all). */
	restore: async ({ request, params, locals }) => {
		await requirePermission(locals, 'clean_timelines');
		const entity = await entityBySlug(locals.supabase, params.slug);
		const keys = keysFrom(await request.formData(), 'restore');
		const { error } = await locals.supabase.rpc('restore_timeline_items', { p_entity: entity.id, p_keys: keys.length ? keys : null });
		if (error) return fail(isMissingFunction(error) ? 503 : 400, { error: isMissingFunction(error) ? missing : dbMessage(error) });
		return { ok: keys.length === 1 ? 'Restored.' : 'Restored everything ignored on this page.' };
	},
	apply: async ({ request, params, locals }) => {
		await requirePermission(locals, 'clean_timelines');
		const entity = await entityBySlug(locals.supabase, params.slug);
		const keys = (await request.formData()).getAll('key').map(String).filter(Boolean);
		if (!keys.length) return fail(400, { error: 'Tick at least one fix to apply.' });
		const { data, error } = await locals.supabase.rpc('normalize_timeline', { p_entity: entity.id, p_keys: keys });
		if (error) return fail(isMissingFunction(error) ? 503 : 400, { error: isMissingFunction(error) ? 'The database is behind this version of the app: an admin has to run the migrate step.' : dbMessage(error) });
		const r = data as { applied: number; remaining: number };
		return {
			ok: `Applied ${r.applied} edit${r.applied === 1 ? '' : 's'}.${r.remaining ? ` ${r.remaining} more fix${r.remaining === 1 ? '' : 'es'} now proposed.` : ''}`
		};
	}
};
