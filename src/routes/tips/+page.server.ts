import { requirePermission } from '$lib/server/db';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, url }) => {
	await requirePermission(locals, 'review_tips');
	const status = url.searchParams.get('status') ?? 'open';
	let q = locals.supabase.from('tips_view').select('*').order('created_at', { ascending: false }).limit(200);
	q = status === 'open' ? q.in('status', ['new', 'reviewing']) : status === 'all' ? q : q.eq('status', status);
	const [{ data: tips }, { data: counts }] = await Promise.all([q, locals.supabase.rpc('tip_counts')]);
	return {
		status,
		tips: tips ?? [],
		counts: Object.fromEntries((counts ?? []).map((c: { status: string; n: number }) => [c.status, c.n])) as Record<string, number>
	};
};
