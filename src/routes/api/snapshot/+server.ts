import { error, json } from '@sveltejs/kit';
import { visibilityCache } from '$lib/server/cache';
import type { RequestHandler } from './$types';

const isDate = (s: string | null): s is string => !!s && /^\d{4}-\d{2}-\d{2}$/.test(s);

/** GeoJSON of everything standing (and, optionally, gone) on a date. */
export const GET: RequestHandler = async ({ url, locals, setHeaders, cookies }) => {
	const at = url.searchParams.get('at');
	if (!isDate(at)) error(400, 'at must be YYYY-MM-DD');
	const kinds = url.searchParams.get('kinds')?.split(',').filter(Boolean);
	const bbox = url.searchParams.get('bbox')?.split(',').map(Number);

	const { data, error: err } = await locals.supabase.rpc('map_snapshot', {
		p_at: at,
		p_kinds: kinds?.length ? kinds : null,
		p_ghosts: url.searchParams.get('ghosts') !== '0',
		p_tag: url.searchParams.get('tag') || null,
		...(bbox?.length === 4 && bbox.every(Number.isFinite)
			? { p_west: bbox[0], p_south: bbox[1], p_east: bbox[2], p_north: bbox[3] }
			: {})
	});
	if (err) error(500, err.message);
	setHeaders(visibilityCache(cookies));
	return json(data);
};
