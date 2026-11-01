import { fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';

const safeNext = (n: string | null) => (n && n.startsWith('/') && !n.startsWith('//') ? n : '/');

export const load: PageServerLoad = async ({ locals, url }) => {
	const { user } = await locals.safeGetSession();
	if (user) redirect(303, safeNext(url.searchParams.get('next')));
	return { next: safeNext(url.searchParams.get('next')) };
};

export const actions: Actions = {
	signin: async ({ request, locals }) => {
		const fd = await request.formData();
		const email = String(fd.get('email') ?? '').trim();
		const { error } = await locals.supabase.auth.signInWithPassword({ email, password: String(fd.get('password') ?? '') });
		if (error) return fail(400, { mode: 'signin', email, error: error.message });
		redirect(303, safeNext(String(fd.get('next'))));
	},
	signup: async ({ request, locals, url }) => {
		const fd = await request.formData();
		const { data: settings } = await locals.supabase.from('site_settings').select('allow_signups').single();
		if (settings && !settings.allow_signups) return fail(403, { mode: 'signup', email: '', error: 'New sign-ups are closed.' });
		const email = String(fd.get('email') ?? '').trim();
		const displayName = String(fd.get('display_name') ?? '').trim();
		const { data, error } = await locals.supabase.auth.signUp({
			email,
			password: String(fd.get('password') ?? ''),
			options: {
				data: { display_name: displayName },
				emailRedirectTo: `${url.origin}/auth/callback?next=${encodeURIComponent(safeNext(String(fd.get('next'))))}`
			}
		});
		if (error) return fail(400, { mode: 'signup', email, error: error.message });
		if (data.session) redirect(303, safeNext(String(fd.get('next'))));
		return { mode: 'signup', email, message: 'Check your email to confirm your account.' };
	},
	magic: async ({ request, locals, url }) => {
		const fd = await request.formData();
		const email = String(fd.get('email') ?? '').trim();
		const { error } = await locals.supabase.auth.signInWithOtp({
			email,
			options: { emailRedirectTo: `${url.origin}/auth/callback?next=${encodeURIComponent(safeNext(String(fd.get('next'))))}` }
		});
		if (error) return fail(400, { mode: 'magic', email, error: error.message });
		return { mode: 'magic', email, message: 'Sign-in link sent. Check your email.' };
	}
};
