import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ parent }) => {
	const { perms } = await parent();
	redirect(303, perms.includes('manage_settings') ? '/admin/settings' : perms.includes('manage_users') ? '/admin/users' : '/admin/vocabulary');
};
