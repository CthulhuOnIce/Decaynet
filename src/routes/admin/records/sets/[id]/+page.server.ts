import { error, fail, redirect } from '@sveltejs/kit';
import { requirePermission } from '$lib/server/db';
import { dbMessage, str } from '$lib/server/forms';
import { SET_COOKIE, logNames } from '$lib/server/records';
import type { LogRow } from '$lib/records';
import type { Actions, PageServerLoad } from './$types';

const PER = 300;

export const load: PageServerLoad = async ({ parent, locals, params, url }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, `/login?next=${encodeURIComponent(url.pathname)}`);
	if (!perms.includes('manage_records')) error(403, 'Records is for admins (the “Manage records” permission).');
	const sb = locals.supabase;
	const pageNo = Math.max(1, Number(url.searchParams.get('page')) || 1);
	const [set, log, undo] = await Promise.all([
		sb.from('change_sets').select('*').eq('id', params.id).maybeSingle(),
		sb
			.from('change_log')
			.select('id, table_name, op, row_id, entity_id, old_data, new_data, created_at', { count: 'exact' })
			.eq('change_set_id', params.id)
			.order('id', { ascending: false })
			.range((pageNo - 1) * PER, pageNo * PER - 1),
		sb.rpc('records_undo', { p_set: params.id, p_preview: true })
	]);
	if (!set.data) error(404, 'No such change set');
	const rows = (log.data ?? []) as LogRow[];
	return {
		set: set.data as { id: string; title: string; context: Record<string, string | null>; created_at: string; updated_at: string; undone_at: string | null; actor_id: string },
		rows,
		total: log.count ?? rows.length,
		pageNo,
		per: PER,
		undo: (undo.data ?? null) as { undone: boolean; changes: number; conflicts: { name: string | null; table: string; at: string }[] } | null,
		undoError: undo.error ? dbMessage(undo.error) : null,
		...(await logNames(sb, rows))
	};
};

export const actions: Actions = {
	undo: async ({ locals, params, cookies }) => {
		await requirePermission(locals, 'manage_records');
		const { data, error: err } = await locals.supabase.rpc('records_undo', { p_set: params.id, p_preview: false });
		if (err) return fail(400, { error: dbMessage(err) });
		const r = data as { undone: boolean; changes: number };
		if (!r.undone) return fail(409, { error: 'Not undone: some of it was changed again since (listed below).' });
		if (cookies.get(SET_COOKIE) === params.id) cookies.delete(SET_COOKIE, { path: '/admin/records' });
		return { undone: r.changes };
	},
	rename: async ({ request, locals, params }) => {
		await requirePermission(locals, 'manage_records');
		const title = (str(await request.formData(), 'title') ?? '').slice(0, 200);
		const { error: err } = await locals.supabase.from('change_sets').update({ title }).eq('id', params.id);
		if (err) return fail(400, { error: dbMessage(err) });
		return { renamed: true };
	}
};
