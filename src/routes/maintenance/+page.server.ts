import type { PageServerLoad } from './$types';

const ISSUES: Record<string, string> = {
	thin_article: 'Thin or missing article',
	unsourced: 'No citations on any fact',
	no_geometry: 'Not on the map',
	unlocated: 'Event / media with no location',
	no_start_date: 'No start date',
	no_lifecycle: 'No condition history',
	no_media: 'No photos or documents',
	orphan: 'Not connected to anything'
};

export const load: PageServerLoad = async ({ locals, url }) => {
	const sb = locals.supabase;
	const issue = url.searchParams.get('issue') ?? '';
	const status = url.searchParams.get('status') ?? '';

	const { data: statuses } = await sb.from('article_statuses').select('id').order('sort');
	const statusCounts = await Promise.all(
		(statuses ?? []).map(async (s) => {
			const { count } = await sb.from('articles').select('*', { count: 'exact', head: true }).eq('status', s.id);
			return [s.id, count ?? 0] as const;
		})
	);
	const issueCounts = await Promise.all(
		Object.keys(ISSUES).map(async (k) => {
			const { count } = await sb.from('entity_health').select('id', { count: 'exact', head: true }).contains('issues', [k]);
			return [k, count ?? 0] as const;
		})
	);

	let q = sb.from('entity_health').select('*').order('article_updated_at', { ascending: true }).limit(200);
	if (issue) q = q.contains('issues', [issue]);
	if (status) q = q.eq('article_status', status);
	const { data: rows } = await q;

	return {
		issue,
		status,
		issues: ISSUES,
		statusCounts: Object.fromEntries(statusCounts) as Record<string, number>,
		issueCounts: Object.fromEntries(issueCounts) as Record<string, number>,
		rows: rows ?? []
	};
};
