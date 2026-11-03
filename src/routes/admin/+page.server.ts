import { reviewCount } from '$lib/server/timelineReview';
import type { PageServerLoad } from './$types';

/** Overview: what needs attention, and where each admin tool lives. */
export const load: PageServerLoad = async ({ parent, locals }) => {
	const { perms, openTips, user } = await parent();
	const sb = locals.supabase;
	const has = (p: string) => perms.includes(p as never);
	const count = async (q: PromiseLike<{ count: number | null }>) => (await q).count ?? 0;
	const [timelines, users, suspended, privatePages, imports] = await Promise.all([
		// from the cached review list; null while it's being worked out (or the database predates it)
		Promise.resolve(has('clean_timelines') && user ? reviewCount(sb, user.id) : null),
		has('manage_users') ? count(sb.from('profiles').select('id', { count: 'exact', head: true })) : Promise.resolve(null),
		has('manage_users') ? count(sb.from('profiles').select('id', { count: 'exact', head: true }).eq('suspended', true)) : Promise.resolve(null),
		count(sb.from('entities').select('id', { count: 'exact', head: true }).eq('is_private', true)),
		has('bulk_edit') ? count(sb.from('import_batches').select('id', { count: 'exact', head: true })) : Promise.resolve(null)
	]);
	return { stats: { timelines, users, suspended, privatePages, imports, openTips } };
};
