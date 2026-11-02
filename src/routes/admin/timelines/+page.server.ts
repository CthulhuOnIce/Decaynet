import { requirePermission } from '$lib/server/db';
import { dbFailure } from '$lib/server/schema';
import type { PageServerLoad } from './$types';

interface ReviewRow {
	entity_id: string;
	slug: string;
	name: string;
	kind: string;
	fixes: number;
	suggestions: number;
	notes: number;
	sections: string[];
}

export const load: PageServerLoad = async ({ locals, url }) => {
	await requirePermission(locals, 'clean_timelines');
	const section = url.searchParams.get('section') ?? '';
	const { data, error } = await locals.supabase.rpc('timeline_review', { p_limit: 2000 });
	if (error) dbFailure(error, 'The Timelines list');
	const rows = (data ?? []) as ReviewRow[];
	const counts: Record<string, number> = {};
	for (const r of rows) for (const x of r.sections) counts[x] = (counts[x] ?? 0) + 1;
	return { rows: section ? rows.filter((r) => r.sections.includes(section)) : rows, total: rows.length, counts, section };
};
