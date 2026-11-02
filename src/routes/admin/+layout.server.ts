import { error, redirect } from '@sveltejs/kit';
import { ADMIN_PERMS } from '$lib/types';
import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async ({ parent }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, '/login?next=/admin');
	if (!ADMIN_PERMS.some((p) => perms.includes(p))) error(403, 'Admins and moderators only.');
	return {};
};
