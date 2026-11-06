import { loadTags } from '$lib/server/db';
import { isSearch, readParams, toQuery, type SearchResult } from '$lib/advancedSearch';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ url, locals }) => {
	const params = readParams(url.searchParams);
	const tags = await loadTags(locals.supabase);
	if (!isSearch(params)) return { params, tags, results: [] as SearchResult[], total: 0, searched: false, error: null };
	const { data, error } = await locals.supabase.rpc('advanced_search', { p: toQuery(params) });
	const results = (data ?? []) as SearchResult[];
	return { params, tags, results, total: results[0]?.total ?? 0, searched: true, error: error?.message ?? null };
};
