import { requirePermission } from '$lib/server/db';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, url }) => {
	await requirePermission(locals, 'clean_timelines');
	const rule = url.searchParams.get('rule') ?? '';
	const { data, error } = await locals.supabase.rpc('timeline_review', { p_limit: 2000 });
	if (error) throw new Error(error.message);
	const rows = (data ?? []) as { entity_id: string; slug: string; name: string; kind: string; fixes: number; rules: string[] }[];
	const counts: Record<string, number> = {};
	for (const r of rows) for (const x of r.rules) counts[x] = (counts[x] ?? 0) + 1;
	return { rows: rule ? rows.filter((r) => r.rules.includes(rule)) : rows, total: rows.length, counts, rule };
};
