import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { env as priv } from '$env/dynamic/private';
import { env as pub } from '$env/dynamic/public';

let client: SupabaseClient | null | undefined;

/**
 * Service-role client. Bypasses RLS, so only use it for things the app server
 * must vouch for itself: anonymous tip intake (after captcha + rate limit),
 * reading site secrets, and listing auth users for admins. Returns null when
 * SUPABASE_SERVICE_ROLE_KEY isn't configured.
 */
export function serviceClient(): SupabaseClient | null {
	if (client !== undefined) return client;
	const key = priv.SUPABASE_SERVICE_ROLE_KEY;
	const url = priv.SUPABASE_INTERNAL_URL || pub.PUBLIC_SUPABASE_URL;
	client = key && url ? createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } }) : null;
	return client;
}

export async function getSecret(key: string): Promise<string | null> {
	const sb = serviceClient();
	if (!sb) return null;
	const { data } = await sb.from('site_secrets').select('value').eq('key', key).maybeSingle();
	return data?.value ?? null;
}
