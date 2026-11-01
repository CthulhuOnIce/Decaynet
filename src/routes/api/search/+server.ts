import { error, json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

/** Autocomplete across canonical and historic names. */
export const GET: RequestHandler = async ({ url, locals }) => {
	const q = (url.searchParams.get('q') ?? '').trim();
	if (q.length < 2) return json([]);
	const kinds = url.searchParams.get('kinds')?.split(',').filter(Boolean);
	const { data, error: err } = await locals.supabase.rpc('search_entities', {
		p_q: q,
		p_kinds: kinds?.length ? kinds : null,
		p_limit: Number(url.searchParams.get('limit') ?? 12)
	});
	if (err) error(500, err.message);
	return json(data ?? []);
};
