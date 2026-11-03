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

interface Summary {
	pages: Record<string, number>;
	flagged?: Record<string, number>;
	issues: { kind: string; issue: string; n: number }[];
	statuses: { kind: string; status: string; n: number }[];
}

export const load: PageServerLoad = async ({ locals, url }) => {
	const sb = locals.supabase;
	const issue = url.searchParams.get('issue') ?? '';
	const status = url.searchParams.get('status') ?? '';
	const kind = url.searchParams.get('kind') ?? '';

	// One query for every count, per kind of page (migration 0032)
	const [{ data: summary }, { count: privateCount }] = await Promise.all([
		sb.rpc('maintenance_summary'),
		sb.from('entities').select('id', { count: 'exact', head: true }).eq('is_private', true)
	]);
	const s: Summary = (summary as Summary | null) ?? { pages: {}, issues: [], statuses: [] };
	const inKind = <T extends { kind: string }>(rows: T[]) => (kind ? rows.filter((r) => r.kind === kind) : rows);
	const sum = (rows: { n: number }[]) => rows.reduce((a, r) => a + r.n, 0);

	const issueCounts = Object.fromEntries(Object.keys(ISSUES).map((k) => [k, sum(inKind(s.issues).filter((r) => r.issue === k))]));
	const statusCounts: Record<string, number> = {};
	for (const r of inKind(s.statuses)) statusCounts[r.status] = (statusCounts[r.status] ?? 0) + r.n;

	let q = sb.from('entity_health').select('*').order('article_updated_at', { ascending: true }).limit(200);
	if (kind) q = q.eq('kind', kind);
	if (issue) q = q.contains('issues', [issue]);
	if (status) q = q.eq('article_status', status);
	const { data: rows } = await q;

	return {
		issue,
		status,
		kind,
		issues: ISSUES,
		statusCounts,
		issueCounts,
		kindPages: s.pages,
		// per kind: how many pages need something
		kindFlagged: s.flagged ?? {},
		privateCount: privateCount ?? 0,
		rows: rows ?? []
	};
};
