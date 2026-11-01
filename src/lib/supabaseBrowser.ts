import { createBrowserClient } from '@supabase/ssr';
import type { SupabaseClient } from '@supabase/supabase-js';
import { env } from '$env/dynamic/public';

let client: SupabaseClient | undefined;

/** Browser-side client: only used for direct-to-storage uploads (big files skip the app server). */
export function browserClient(): SupabaseClient {
	client ??= createBrowserClient(env.PUBLIC_SUPABASE_URL!, env.PUBLIC_SUPABASE_ANON_KEY!);
	return client;
}
