import { createServerClient } from '@supabase/ssr';
import { env } from '$env/dynamic/public';
import { env as priv } from '$env/dynamic/private';
import { AUTH_COOKIE } from '$lib/supabaseConfig';
import type { Handle, ServerInit } from '@sveltejs/kit';
import { ensureBootstrapped } from '$lib/server/bootstrap';

/** On startup: create the first admin from env, or print a /setup code. */
export const init: ServerInit = async () => {
	await ensureBootstrapped();
};

export const handle: Handle = async ({ event, resolve }) => {
	// The server may reach Supabase on a private address (Docker network); browsers use the public one.
	const url = priv.SUPABASE_INTERNAL_URL || env.PUBLIC_SUPABASE_URL;
	const key = env.PUBLIC_SUPABASE_ANON_KEY;
	if (!url || !key) {
		throw new Error(
			'PUBLIC_SUPABASE_URL and PUBLIC_SUPABASE_ANON_KEY must be set (copy .env.example to .env).'
		);
	}

	event.locals.supabase = createServerClient(url, key, {
		cookieOptions: AUTH_COOKIE,
		cookies: {
			getAll: () => event.cookies.getAll(),
			setAll: (cookiesToSet, headers) => {
				for (const { name, value, options } of cookiesToSet) {
					event.cookies.set(name, value, { ...options, path: '/' });
				}
				try {
					if (headers) event.setHeaders(headers);
				} catch {
					// headers already set for this response
				}
			}
		}
	});

	/**
	 * getSession() reads the cookie without validating it; getUser() asks the
	 * auth server. Only trust the user after getUser() succeeds.
	 */
	event.locals.safeGetSession = async () => {
		const {
			data: { session }
		} = await event.locals.supabase.auth.getSession();
		if (!session) return { session: null, user: null };
		const {
			data: { user },
			error
		} = await event.locals.supabase.auth.getUser();
		if (error) return { session: null, user: null };
		return { session, user };
	};

	return resolve(event, {
		filterSerializedResponseHeaders: (name) =>
			name === 'content-range' || name === 'x-supabase-api-version'
	});
};
