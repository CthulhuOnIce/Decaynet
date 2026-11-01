import { fail, redirect } from '@sveltejs/kit';
import { dbMessage, str } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	const { user } = await locals.safeGetSession();
	if (!user) redirect(303, '/login?next=/account');
	const { data: permissions } = await locals.supabase.from('permissions').select('*').order('sort');
	return { email: user.email, permissions: permissions ?? [] };
};

export const actions: Actions = {
	profile: async ({ request, locals }) => {
		const { user } = await locals.safeGetSession();
		if (!user) return fail(401, { section: 'profile', error: 'Signed out.' });
		const fd = await request.formData();
		const display_name = str(fd, 'display_name');
		if (!display_name) return fail(400, { section: 'profile', error: 'Display name is required.' });
		const { error } = await locals.supabase
			.from('profiles')
			.update({ display_name, bio: str(fd, 'bio'), website: str(fd, 'website') })
			.eq('id', user.id);
		if (error) return fail(400, { section: 'profile', error: dbMessage(error) });
		return { section: 'profile', ok: 'Profile saved.' };
	},
	email: async ({ request, locals, url }) => {
		const fd = await request.formData();
		const email = str(fd, 'email');
		if (!email) return fail(400, { section: 'email', error: 'Enter an email.' });
		const { error } = await locals.supabase.auth.updateUser(
			{ email },
			{ emailRedirectTo: `${url.origin}/auth/callback?next=/account` }
		);
		if (error) return fail(400, { section: 'email', error: error.message });
		return { section: 'email', ok: 'Check both inboxes to confirm the change.' };
	},
	password: async ({ request, locals }) => {
		const fd = await request.formData();
		const password = String(fd.get('password') ?? '');
		if (password.length < 8) return fail(400, { section: 'password', error: 'Use at least 8 characters.' });
		if (password !== String(fd.get('confirm') ?? '')) return fail(400, { section: 'password', error: 'Passwords do not match.' });
		const { error } = await locals.supabase.auth.updateUser({ password });
		if (error) return fail(400, { section: 'password', error: error.message });
		return { section: 'password', ok: 'Password changed.' };
	}
};
