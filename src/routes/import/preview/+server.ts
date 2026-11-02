import { error, json } from '@sveltejs/kit';
import { getGeonamesUser } from '$lib/server/admin';
import { requirePermission, loadSettings } from '$lib/server/db';
import { buildPreview } from '$lib/server/importers/plan';
import type { ImportOptions } from '$lib/importTypes';
import type { RequestHandler } from './$types';

/**
 * Fetch live from the enabled sources (OpenHistoricalMap, OpenStreetMap, Wikidata,
 * Wikipedia, Wikimedia Commons, GeoNames), match against existing pages,
 * and return a plan. Read-only: nothing is written here.
 */
export const POST: RequestHandler = async ({ request, locals }) => {
	await requirePermission(locals, 'bulk_edit');
	const opts = (await request.json()) as ImportOptions;
	const settings = await loadSettings(locals.supabase);
	// Both services ask for a descriptive User-Agent with a contact point
	const ua = `${settings.site_name.replace(/[^\w .-]/g, '')}/1.0 (Decaynet; ${settings.source_code_url})`;
	try {
		return json(await buildPreview(locals.supabase, opts, ua, settings.content_language, { geonamesUser: await getGeonamesUser() }));
	} catch (e) {
		error(400, (e as Error).message);
	}
};
