import type { Session, SupabaseClient, User } from '@supabase/supabase-js';
import type { Profile } from '$lib/types';

declare global {
	/** Newest migration this build expects, from supabase/migrations at build time (vite.config.ts). */
	const __SCHEMA_VERSION__: string;

	namespace App {
		interface Error {
			message: string;
		}
		interface Locals {
			supabase: SupabaseClient;
			safeGetSession: () => Promise<{ session: Session | null; user: User | null }>;
		}
		interface PageData {
			user?: User | null;
			profile?: Profile | null;
		}
	}
}

export {};
