import { redirect } from '@sveltejs/kit';
import type { EmailOtpType } from '@supabase/supabase-js';
import type { RequestHandler } from './$types';

/** Token-hash flow, for email templates using {{ .TokenHash }}. */
export const GET: RequestHandler = async ({ url, locals }) => {
	const token_hash = url.searchParams.get('token_hash');
	const type = url.searchParams.get('type') as EmailOtpType | null;
	const next = url.searchParams.get('next') ?? '/';
	const safe = next.startsWith('/') && !next.startsWith('//') ? next : '/';
	if (token_hash && type) {
		const { error } = await locals.supabase.auth.verifyOtp({ token_hash, type });
		if (!error) redirect(303, safe);
	}
	redirect(303, '/login?error=link');
};
