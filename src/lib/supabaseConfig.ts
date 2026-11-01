/**
 * One cookie name for every Supabase client (server and browser). By default
 * @supabase/ssr derives the name from the project URL, which breaks sign-in
 * when the server reaches Supabase on a different address than the browser
 * (e.g. SUPABASE_INTERNAL_URL inside Docker).
 */
export const AUTH_COOKIE = { name: 'sb-decaynet-auth-token' };
