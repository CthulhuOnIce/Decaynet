import type { ChronologyRow } from '$lib/types';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ url, locals }) => {
	const now = new Date().getFullYear();
	const from = Number(url.searchParams.get('from')) || 1880;
	const to = Number(url.searchParams.get('to')) || now;
	const kind = url.searchParams.get('kind') || null;
	const picked = url.searchParams.getAll('cats').flatMap((c) => c.split(','));
	const cats = picked.length ? picked : ['event', 'start', 'end', 'status'];

	const { data, error } = await locals.supabase.rpc('chronology', {
		p_from: `${from}-01-01`,
		p_to: `${to}-12-31`,
		p_kinds: kind ? [kind] : null,
		p_limit: 2000
	});
	const rows = ((data ?? []) as ChronologyRow[]).filter((r) => cats.includes(r.category));

	// Group by decade
	const decades = new Map<number, ChronologyRow[]>();
	for (const r of rows) {
		const d = Math.floor(Number(r.at.slice(0, 4)) / 10) * 10;
		if (!decades.has(d)) decades.set(d, []);
		decades.get(d)!.push(r);
	}
	return {
		from,
		to,
		kind,
		cats,
		error: error?.message ?? null,
		decades: [...decades.entries()].map(([decade, items]) => ({ decade, items }))
	};
};
