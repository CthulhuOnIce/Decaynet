import { error } from '@sveltejs/kit';
import type { SupabaseClient } from '@supabase/supabase-js';

/** The newest migration this build of the app needs (baked in at build time). */
export const REQUIRED_SCHEMA: string = __SCHEMA_VERSION__;

export interface SchemaStatus {
	/** false: the database is behind this app; run the migrate step */
	ok: boolean;
	/** newest migration applied, or null if unknown */
	have: string | null;
	need: string;
}

type DbError = { message: string; code?: string } | null;

/** PostgREST / Postgres "that function doesn't exist": the database predates it. */
export const isMissingFunction = (e: DbError) =>
	!!e && (e.code === 'PGRST202' || e.code === '42883' || /could not find the function|function .* does not exist/i.test(e.message));

let cache: { at: number; status: SchemaStatus } | null = null;

/** Is the database up to date with this app? Cached (briefly while it's behind, so a fix shows quickly). */
export async function schemaStatus(sb: SupabaseClient): Promise<SchemaStatus> {
	if (cache && Date.now() - cache.at < (cache.status.ok ? 300_000 : 15_000)) return cache.status;
	const { data, error: err } = await sb.rpc('schema_version');
	let status: SchemaStatus;
	if (err) {
		// before migration 0021 there is no schema_version(): certainly behind; other errors: don't guess
		status = isMissingFunction(err) ? { ok: false, have: null, need: REQUIRED_SCHEMA } : { ok: true, have: null, need: REQUIRED_SCHEMA };
	} else {
		const have = (data as string | null) ?? null;
		status = { ok: !have || have >= REQUIRED_SCHEMA, have, need: REQUIRED_SCHEMA };
	}
	cache = { at: Date.now(), status };
	return status;
}

/**
 * For a page built on a newer database function: if the database doesn't have
 * it yet, answer 503 with what to do instead of a bare internal error.
 */
export function dbFailure(e: NonNullable<DbError>, feature: string): never {
	cache = null;
	if (isMissingFunction(e))
		error(503, `${feature} needs a newer database than this site has. An admin has to run the migrate step (see the notice on any page while signed in as an admin).`);
	error(500, e.message);
}
