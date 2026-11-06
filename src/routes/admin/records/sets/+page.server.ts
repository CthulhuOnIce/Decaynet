import { error, redirect } from '@sveltejs/kit';
import type { ChangeSet } from '$lib/records';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ parent, locals, url }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, `/login?next=${encodeURIComponent(url.pathname)}`);
	if (!perms.includes('manage_records')) error(403, 'Records is for admins (the “Manage records” permission).');
	const { data } = await locals.supabase.rpc('records_sets', { p_limit: 200 });
	return { sets: (data ?? []) as (ChangeSet & { pages: number })[] };
};
