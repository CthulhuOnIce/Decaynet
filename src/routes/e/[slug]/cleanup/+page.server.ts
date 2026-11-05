import { fail } from '@sveltejs/kit';
import { entityBySlug, requirePermission } from '$lib/server/db';
import { dbMessage } from '$lib/server/forms';
import { dbFailure, isMissingFunction } from '$lib/server/schema';
import { invalidateReview } from '$lib/server/timelineReview';
import type { TimelineFix } from '$lib/timelineCleanup';
import type { Actions, PageServerLoad } from './$types';

export interface InteriorSpace {
	id: string;
	slug: string;
	name: string;
	depth: number;
	/** the fixes cleanup would apply on it now */
	keys: string[];
}

export const load: PageServerLoad = async ({ params, locals }) => {
	await requirePermission(locals, 'clean_timelines');
	const sb = locals.supabase;
	const entity = await entityBySlug(sb, params.slug);
	const [plan, ignored, spaces, states, geoms, addresses] = await Promise.all([
		sb.rpc('timeline_plan', { p_entity: entity.id }),
		// items ignored while the timeline is as it is now (none on a database before migration 0032)
		sb.rpc('timeline_dismissed_keys', { p_entity: entity.id }),
		// storefronts, suites and halls inside it, at any depth (none before migration 0041)
		sb.rpc('interior_space_fixes', { p_entity: entity.id }),
		sb.from('entity_states').select('id, status, valid_from, valid_from_precision, valid_to, valid_to_precision, note, lifecycle_statuses(label, color, sort)').eq('entity_id', entity.id).order('valid_from', { nullsFirst: true }),
		sb.from('entity_geometries').select('id, role, valid_from, valid_from_precision, valid_to, valid_to_precision').eq('entity_id', entity.id).neq('role', 'viewpoint').order('valid_from', { nullsFirst: true }),
		sb.from('addresses').select('id, house_number, unit, raw_address, valid_from, valid_from_precision, valid_to, valid_to_precision, street:entities!addresses_street_id_fkey(name)').eq('entity_id', entity.id).order('valid_from', { nullsFirst: true })
	]);
	if (plan.error) dbFailure(plan.error, 'Timeline cleanup');
	return {
		entity,
		fixes: (plan.data ?? []) as TimelineFix[],
		ignored: (ignored.error ? [] : (ignored.data ?? [])) as string[],
		spaces: (spaces.error ? [] : (spaces.data ?? [])) as InteriorSpace[],
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
		invalidateReview();
		return { ok: `Ignored ${keys.length === 1 ? 'it' : `${keys.length} items`} until this page's timeline changes.` };
	},
	/** Bring ignored items back (one, or all). */
	restore: async ({ request, params, locals }) => {
		await requirePermission(locals, 'clean_timelines');
		const entity = await entityBySlug(locals.supabase, params.slug);
		const keys = keysFrom(await request.formData(), 'restore');
		const { error } = await locals.supabase.rpc('restore_timeline_items', { p_entity: entity.id, p_keys: keys.length ? keys : null });
		if (error) return fail(isMissingFunction(error) ? 503 : 400, { error: isMissingFunction(error) ? missing : dbMessage(error) });
		invalidateReview();
		return { ok: keys.length === 1 ? 'Restored.' : 'Restored everything ignored on this page.' };
	},
	/** The ticked fixes, then (when asked) the default fixes on every space inside the page, parents first. */
	apply: async ({ request, params, locals }) => {
		await requirePermission(locals, 'clean_timelines');
		const entity = await entityBySlug(locals.supabase, params.slug);
		const fd = await request.formData();
		const keys = keysFrom(fd, 'key');
		const spaces = fd.get('spaces') === '1';
		if (!keys.length && !spaces) return fail(400, { error: 'Tick at least one fix to apply.' });
		const failed = (error: { message: string; code?: string }) =>
			fail(isMissingFunction(error) ? 503 : 400, { error: isMissingFunction(error) ? missing : dbMessage(error) });
		const said: string[] = [];
		let remaining = 0;
		if (keys.length) {
			const { data, error } = await locals.supabase.rpc('normalize_timeline', { p_entity: entity.id, p_keys: keys });
			if (error) return failed(error);
			const r = data as { applied: number; remaining: number };
			said.push(`Applied ${plural(r.applied, 'edit')}.`);
			remaining = r.remaining;
		}
		if (spaces) {
			// after the page's own fixes, so the spaces are fitted to its corrected lifespan
			const { data, error } = await locals.supabase.rpc('normalize_interior_spaces', { p_entity: entity.id });
			invalidateReview();
			if (error) return failed(error);
			const r = data as { applied: number; spaces: number; touched: { slug: string; name: string; applied: number }[] };
			said.push(
				r.applied
					? `Tidied ${plural(r.spaces, 'interior space')} (${plural(r.applied, 'edit')}): ${r.touched.map((t) => t.name).join(', ')}.`
					: 'Its interior spaces needed nothing.'
			);
			if (keys.length && r.applied) {
				// the spaces' edits can change what's proposed here
				const plan = await locals.supabase.rpc('timeline_plan', { p_entity: entity.id });
				remaining = ((plan.data ?? []) as TimelineFix[]).filter((f) => f.op !== 'note' && f.default).length;
			}
		}
		invalidateReview();
		if (remaining) said.push(`${plural(remaining, 'more fix', 'more fixes')} now proposed.`);
		return { ok: said.join(' ') };
	}
};

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
