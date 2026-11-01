import { error, json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

/** One entity folded to a single date: powers the map side panel. */
export const GET: RequestHandler = async ({ params, url, locals }) => {
	const at = url.searchParams.get('at') ?? new Date().toISOString().slice(0, 10);
	if (!/^\d{4}-\d{2}-\d{2}$/.test(at)) error(400, 'at must be YYYY-MM-DD');
	if (!/^[0-9a-f-]{36}$/i.test(params.id)) error(400, 'bad id');
	const { data, error: err } = await locals.supabase.rpc('entity_snapshot', { p_entity: params.id, p_at: at });
	if (err) error(500, err.message);
	if (!data) error(404, 'not found');
	return json(data);
};
