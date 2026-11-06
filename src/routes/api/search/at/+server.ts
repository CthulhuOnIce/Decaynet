import { json } from '@sveltejs/kit';
import { TIME_WINDOW } from '$lib/advancedSearch';
import type { RequestHandler } from './$types';

/** The map's search: what was there in its year and the few before, by the names and addresses of then. */
export const GET: RequestHandler = async ({ url, locals }) => {
	const q = (url.searchParams.get('q') ?? '').trim();
	const y = Number(url.searchParams.get('year'));
	if (q.length < 2 || !Number.isInteger(y)) return json([]);
	const { data, error } = await locals.supabase.rpc('advanced_search', {
		p: { q, in: ['names', 'addresses'], from_year: y - TIME_WINDOW, to_year: y, limit: 12 }
	});
	if (error) return json({ error: error.message }, { status: 500 });
	return json(data ?? []);
};
