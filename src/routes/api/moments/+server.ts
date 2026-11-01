import { error, json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

/** Events and dated media within ±years of a date, located on the map. */
export const GET: RequestHandler = async ({ url, locals, setHeaders }) => {
	const at = url.searchParams.get('at');
	if (!at || !/^\d{4}-\d{2}-\d{2}$/.test(at)) error(400, 'at must be YYYY-MM-DD');
	const years = Math.max(0, Math.min(50, Number(url.searchParams.get('years') ?? 5) || 5));
	const { data, error: err } = await locals.supabase.rpc('moments_near', { p_at: at, p_years: years });
	if (err) error(500, err.message);
	setHeaders({ 'cache-control': 'public, max-age=30' });
	return json(data);
};
