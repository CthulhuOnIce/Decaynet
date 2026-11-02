import type { PageServerLoad } from './$types';

/** Overview: what needs attention, and where each admin tool lives. */
export const load: PageServerLoad = async ({ parent, locals }) => {
	const { perms, openTips } = await parent();
	const sb = locals.supabase;
	const has = (p: string) => perms.includes(p as never);
	const count = async (q: PromiseLike<{ count: number | null }>) => (await q).count ?? 0;
	const [timelines, users, suspended, privatePages, imports] = await Promise.all([
		// null when the database predates timeline cleanup (the layout banner explains)
		has('clean_timelines') ? sb.rpc('timeline_review', { p_limit: 2000 }).then((r) => (r.error ? null : (r.data ?? []).length)) : Promise.resolve(null),
		has('manage_users') ? count(sb.from('profiles').select('id', { count: 'exact', head: true })) : Promise.resolve(null),
		has('manage_users') ? count(sb.from('profiles').select('id', { count: 'exact', head: true }).eq('suspended', true)) : Promise.resolve(null),
		count(sb.from('entities').select('id', { count: 'exact', head: true }).eq('is_private', true)),
		has('bulk_edit') ? count(sb.from('import_batches').select('id', { count: 'exact', head: true })) : Promise.resolve(null)
	]);
	return { stats: { timelines, users, suspended, privatePages, imports, openTips } };
};
