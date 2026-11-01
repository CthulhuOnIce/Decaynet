import { redirect } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

/** PKCE flow: magic links and sign-up confirmations land here with ?code=. */
export const GET: RequestHandler = async ({ url, locals }) => {
	const code = url.searchParams.get('code');
	const next = url.searchParams.get('next') ?? '/';
	const safe = next.startsWith('/') && !next.startsWith('//') ? next : '/';
	if (code) {
		const { error } = await locals.supabase.auth.exchangeCodeForSession(code);
		if (!error) redirect(303, safe);
	}
	redirect(303, '/login?error=link');
};
