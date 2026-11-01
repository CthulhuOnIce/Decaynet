import { loadTags } from '$lib/server/db';
import type { ChronologyRow, MapLayer } from '$lib/types';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	const [extent, layers, chrono] = await Promise.all([
		locals.supabase.rpc('timeline_extent'),
		locals.supabase.from('map_layers').select('*').eq('enabled', true).order('depicts_from'),
		locals.supabase.rpc('chronology', { p_from: '1800-01-01', p_limit: 5000 })
	]);

	const minYear: number = Math.min(extent.data?.min_year ?? 1890, 1890);
	const maxYear: number = extent.data?.max_year ?? new Date().getFullYear();

	// Histogram of "things happening" per year for the slider
	const density = new Array(maxYear - minYear + 1).fill(0);
	for (const row of (chrono.data ?? []) as ChronologyRow[]) {
		const y = Number(row.at.slice(0, 4));
		if (y >= minYear && y <= maxYear) density[y - minYear] += 1;
	}

	return {
		minYear,
		maxYear,
		density,
		layers: (layers.data ?? []) as MapLayer[],
		tags: (await loadTags(locals.supabase)).filter((t) => t.total_uses > 0)
	};
};
