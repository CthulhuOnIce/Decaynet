import { redirect } from '@sveltejs/kit';
import type { SearchHit } from '$lib/types';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ url, locals }) => {
	const q = (url.searchParams.get('q') ?? '').trim();
	if (!q) return { q, hits: [] as SearchHit[] };
	const { data } = await locals.supabase.rpc('search_entities', { p_q: q, p_limit: 50 });
	const hits = (data ?? []) as SearchHit[];
	// Exact title hit and nothing else close: go straight there, like a wiki
	if (url.searchParams.get('go') !== '0' && hits.length === 1 && hits[0].name.toLowerCase() === q.toLowerCase())
		redirect(303, `/e/${hits[0].slug}`);
	return { q, hits };
};
