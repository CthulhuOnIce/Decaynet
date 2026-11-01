import { fail, redirect } from '@sveltejs/kit';
import { requirePermission } from '$lib/server/db';
import { dbMessage, str } from '$lib/server/forms';
import { toApplyPayload } from '$lib/server/importers/plan';
import type { PlanItem } from '$lib/importTypes';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ parent, locals }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, '/login?next=/import');
	if (!perms.includes('bulk_edit')) redirect(303, '/');
	const { data: batches } = await locals.supabase
		.from('import_batches')
		.select('*, by:profiles(display_name)')
		.order('created_at', { ascending: false })
		.limit(15);
	return { batches: batches ?? [] };
};

export const actions: Actions = {
	/** Write the rows the editor approved in the preview. */
	apply: async ({ request, locals }) => {
		await requirePermission(locals, 'bulk_edit');
		const fd = await request.formData();
		let items: PlanItem[];
		let bbox: number[];
		try {
			const body = JSON.parse(str(fd, 'plan') ?? '{}');
			items = body.items ?? [];
			bbox = body.bbox ?? [];
		} catch {
			return fail(400, { error: 'The preview could not be read. Fetch it again.' });
		}
		if (!items.length) return fail(400, { error: 'Nothing selected.' });
		const { data: kinds } = await locals.supabase.from('entity_kinds').select('id');
		let payload;
		try {
			payload = toApplyPayload(items, bbox, new Set((kinds ?? []).map((k: { id: string }) => k.id)));
		} catch (e) {
			return fail(400, { error: (e as Error).message });
		}
		const { data, error } = await locals.supabase.rpc('apply_import', { p_plan: payload });
		if (error) return fail(400, { error: dbMessage(error) });
		const applied = data as { batch_id: string; created: number; merged: number };
		if (fd.get('private') === 'on' && applied.created) {
			const r = await locals.supabase.rpc('set_import_privacy', { p_batch: applied.batch_id, p_private: true });
			if (r.error) return fail(400, { error: `Imported, but making the pages private failed: ${dbMessage(r.error)}` });
		}
		return { applied, private: fd.get('private') === 'on' };
	},
	undo: async ({ request, locals }) => {
		await requirePermission(locals, 'moderate');
		const fd = await request.formData();
		const { data, error } = await locals.supabase.rpc('undo_import', { p_batch: str(fd, 'batch') });
		if (error) return fail(400, { error: dbMessage(error) });
		return { undone: data as number };
	}
};
