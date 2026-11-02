import { json } from '@sveltejs/kit';
import { schemaStatus } from '$lib/server/schema';
import type { RequestHandler } from './$types';

/** Liveness + database reachability, for Docker / load-balancer health checks. */
export const GET: RequestHandler = async ({ locals }) => {
	const { error } = await locals.supabase.from('site_settings').select('site_name').limit(1);
	// a database behind the app still serves pages, so it's reported but doesn't fail the check
	const schema = error ? null : await schemaStatus(locals.supabase);
	return json({ ok: !error, db: error ? error.message : 'ok', schema }, { status: error ? 503 : 200 });
};
