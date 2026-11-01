import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

/** Liveness + database reachability, for Docker / load-balancer health checks. */
export const GET: RequestHandler = async ({ locals }) => {
	const { error } = await locals.supabase.from('site_settings').select('site_name').limit(1);
	return json({ ok: !error, db: error ? error.message : 'ok' }, { status: error ? 503 : 200 });
};
