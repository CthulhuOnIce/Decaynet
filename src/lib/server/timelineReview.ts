import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * timeline_review() runs the cleanup planner on every page: about 3 ms a page,
 * so ~15 s for a city's worth. The list is cached here per person for a few
 * minutes; applying fixes or ignoring items clears it, and the review page can
 * refresh it. The admin dashboard only reads the cache (starting the work in
 * the background if there's none), so it never waits for it.
 */

export interface ReviewRow {
	entity_id: string;
	slug: string;
	name: string;
	kind: string;
	fixes: number;
	suggestions: number;
	notes: number;
	sections: string[];
}

interface Entry {
	at: number;
	rows: ReviewRow[];
}

const TTL = 10 * 60_000;
const done = new Map<string, Entry>();
const running = new Map<string, Promise<Entry>>();

function compute(sb: SupabaseClient, key: string): Promise<Entry> {
	const already = running.get(key);
	if (already) return already;
	const p = (async () => {
		const { data, error } = await sb.rpc('timeline_review', { p_limit: 2000 });
		if (error) throw error;
		const entry = { at: Date.now(), rows: (data ?? []) as ReviewRow[] };
		done.set(key, entry);
		return entry;
	})().finally(() => running.delete(key));
	running.set(key, p);
	return p;
}

const fresh = (e: Entry | undefined) => !!e && Date.now() - e.at < TTL;

/** The review list (cached; `refresh` works it out again). Throws the database error, if any. */
export async function reviewRows(sb: SupabaseClient, userId: string, refresh = false): Promise<Entry> {
	const e = done.get(userId);
	if (!refresh && fresh(e)) return e!;
	return compute(sb, userId);
}

/** How many pages need a look, if known; otherwise null, and it's worked out in the background. */
export function reviewCount(sb: SupabaseClient, userId: string): number | null {
	const e = done.get(userId);
	if (fresh(e)) return e!.rows.length;
	compute(sb, userId).catch(() => {}); // e.g. the database predates timeline cleanup
	return null;
}

/** After fixes are applied or items ignored: everyone's list may have changed. */
export function invalidateReview() {
	done.clear();
}
