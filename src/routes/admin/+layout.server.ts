import { error, redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async ({ parent }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, '/login?next=/admin');
	if (!perms.includes('manage_users') && !perms.includes('manage_settings')) error(403, 'Admins only.');
	return {};
};
