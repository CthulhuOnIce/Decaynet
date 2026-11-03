import { fail, redirect } from '@sveltejs/kit';
import {
	checkSetupCode,
	createAdmin,
	ensureBootstrapped,
	markAdminKnown,
	siteHasAdmin,
	usesSetupCode
} from '$lib/server/bootstrap';
import { serviceClient } from '$lib/server/admin';
import { invalidateSiteData } from '$lib/server/db';
import { str } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	await ensureBootstrapped();
	if (await siteHasAdmin(locals.supabase)) redirect(303, '/');
	return { needsCode: usesSetupCode() };
};

export const actions: Actions = {
	default: async ({ request, locals }) => {
		if (await siteHasAdmin(locals.supabase)) redirect(303, '/');
		const fd = await request.formData();
		const values = {
			name: str(fd, 'name') ?? '',
			email: str(fd, 'email') ?? '',
			site_name: str(fd, 'site_name') ?? '',
			tagline: str(fd, 'tagline') ?? '',
			region_name: str(fd, 'region_name') ?? ''
		};
		const password = String(fd.get('password') ?? '');
		if (usesSetupCode() && !checkSetupCode(str(fd, 'code') ?? ''))
			return fail(403, { values, error: 'That setup code is not right. It is printed in the app’s logs (or is your SETUP_TOKEN).' });
		if (!values.name || !values.email) return fail(400, { values, error: 'Name and email are required.' });
		if (password.length < 8) return fail(400, { values, error: 'Use a password of at least 8 characters.' });
		if (password !== String(fd.get('confirm') ?? '')) return fail(400, { values, error: 'Passwords do not match.' });

		const admin = serviceClient();
		try {
			if (admin) {
				await createAdmin(values.email, password, values.name);
			} else {
				// No service key (simple dev setup): the first sign-up becomes admin
				const { error } = await locals.supabase.auth.signUp({
					email: values.email,
					password,
					options: { data: { display_name: values.name } }
				});
				if (error) throw new Error(error.message);
			}
		} catch (e) {
			return fail(400, { values, error: (e as Error).message });
		}

		const { error: signInError } = await locals.supabase.auth.signInWithPassword({ email: values.email, password });
		if (signInError)
			return fail(400, { values, error: `Admin created, but signing in failed: ${signInError.message}. Try /login.` });
		markAdminKnown();

		const site = Object.fromEntries(
			Object.entries({ site_name: values.site_name, tagline: values.tagline, region_name: values.region_name }).filter(([, v]) => v)
		);
		if (Object.keys(site).length) await (admin ?? locals.supabase).from('site_settings').update(site).eq('id', true);
		invalidateSiteData();
		redirect(303, '/admin/settings?welcome=1');
	}
};
