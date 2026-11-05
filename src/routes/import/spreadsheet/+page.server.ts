import { fail, redirect } from '@sveltejs/kit';
import { loadSettings, loadVocabulary, requirePermission } from '$lib/server/db';
import { FormError, dbMessage, str } from '$lib/server/forms';
import { librarySources } from '$lib/server/sources';
import { applyRows, preview, readSheet, type Choice } from '$lib/server/tableImport';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ parent, locals }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, '/login?next=/import/spreadsheet');
	if (!perms.includes('bulk_edit')) redirect(303, '/');
	const [sources, batches] = await Promise.all([
		librarySources(locals.supabase),
		locals.supabase.from('import_batches').select('*, by:profiles(display_name)').order('created_at', { ascending: false }).limit(40)
	]);
	type Batch = { id: string; sources: string[]; summary: Record<string, unknown> | null; created_at: string; undone_at: string | null; by: { display_name: string } | null };
	return {
		sources,
		batches: ((batches.data ?? []) as Batch[]).filter((b) => b.sources?.includes('spreadsheet')).slice(0, 10)
	};
};

const failed = (e: unknown) => {
	if (e instanceof FormError) return fail(400, { error: e.message });
	throw e;
};

export const actions: Actions = {
	/** Read the sheet and match each row: an existing page, the building it was in, its storefront. */
	preview: async ({ request, locals, url }) => {
		await requirePermission(locals, 'bulk_edit');
		const fd = await request.formData();
		try {
			const sheet = readSheet(str(fd, 'sheet'));
			const [vocab, settings] = await Promise.all([loadVocabulary(locals.supabase), loadSettings(locals.supabase)]);
			return { preview: await preview(locals.supabase, sheet, vocab, settings, url.origin) };
		} catch (e) {
			return failed(e);
		}
	},

	/** Write the rows as reviewed, as one import that can be undone. */
	apply: async ({ request, locals }) => {
		await requirePermission(locals, 'bulk_edit');
		await requirePermission(locals, 'edit_content');
		const fd = await request.formData();
		try {
			const sheet = readSheet(str(fd, 'sheet'));
			let choices: Record<string, Choice>;
			try {
				choices = JSON.parse(str(fd, 'choices') ?? '{}');
			} catch {
				throw new FormError('The preview could not be read. Preview again.');
			}
			const rows = applyRows(sheet, await loadVocabulary(locals.supabase), choices);
			if (!rows.length) throw new FormError('Nothing ticked to import.');
			const o = sheet.options;
			const { data, error } = await locals.supabase.rpc('apply_table_import', {
				p_rows: rows,
				p_source: o.source_id || null,
				p_confidence: o.confidence || 'probable',
				p_private: !!o.private,
				p_label: o.label || null
			});
			if (error) throw new FormError(dbMessage(error));
			return { applied: data as { batch_id: string; created: number; linked: number; points: number; addresses: number } };
		} catch (e) {
			return failed(e);
		}
	},

	undo: async ({ request, locals }) => {
		await requirePermission(locals, 'moderate');
		const { data, error } = await locals.supabase.rpc('undo_import', { p_batch: str(await request.formData(), 'batch') });
		if (error) return fail(400, { error: dbMessage(error) });
		return { undone: data as number };
	}
};
