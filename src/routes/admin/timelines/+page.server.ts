import { requirePermission } from '$lib/server/db';
import { reviewRows } from '$lib/server/timelineReview';
import { dbFailure } from '$lib/server/schema';
import type { PageServerLoad } from './$types';


export const load: PageServerLoad = async ({ locals, url }) => {
	const user = await requirePermission(locals, 'clean_timelines');
	const section = url.searchParams.get('section') ?? '';
	// cached for a few minutes (it runs the planner on every page); ?refresh works it out again
	let review;
	try {
		review = await reviewRows(locals.supabase, user.id, url.searchParams.has('refresh'));
	} catch (e) {
		dbFailure(e as { message: string; code?: string }, 'The Timelines list');
	}
	const rows = review!.rows;
	const counts: Record<string, number> = {};
	for (const r of rows) for (const x of r.sections) counts[x] = (counts[x] ?? 0) + 1;
	return { rows: section ? rows.filter((r) => r.sections.includes(section)) : rows, total: rows.length, counts, section, computedAt: review!.at };
};
