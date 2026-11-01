import type { Cookies } from '@sveltejs/kit';

/**
 * Cache headers for data that depends on who's asking. Signed-in users may
 * see private pages, so their responses must never land in a shared cache.
 * Anonymous responses only contain public data and can be cached briefly.
 */
export function visibilityCache(cookies: Cookies, publicMaxAge = 30): Record<string, string> {
	const signedIn = cookies.getAll().some((c) => c.name.startsWith('sb-'));
	return {
		'cache-control': signedIn ? 'private, no-store' : `public, max-age=${publicMaxAge}`,
		vary: 'Cookie'
	};
}
