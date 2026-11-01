/**
 * Tiny in-memory cache for remote query results. Re-previewing the same area
 * (e.g. right after applying) shouldn't hammer OHM's Overpass, which rejects
 * duplicate concurrent queries, or Wikidata. Matching against the database is
 * always re-run, so the preview stays current.
 */
const store = new Map<string, { at: number; value: unknown }>();
const TTL = 10 * 60_000;

export async function cached<T>(key: string, fn: () => Promise<T>): Promise<T> {
	const hit = store.get(key);
	if (hit && Date.now() - hit.at < TTL) return hit.value as T;
	const value = await fn();
	store.set(key, { at: Date.now(), value });
	if (store.size > 50) store.delete(store.keys().next().value!);
	return value;
}
