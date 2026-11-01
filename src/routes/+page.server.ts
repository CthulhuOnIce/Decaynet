import { loadTags } from '$lib/server/db';
import type { ChronologyRow } from '$lib/types';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	const [extent, chrono] = await Promise.all([
		locals.supabase.rpc('timeline_extent'),
		locals.supabase.rpc('chronology', { p_from: '1800-01-01', p_limit: 5000 })
	]);

	const { data: settings } = await locals.supabase.from('site_settings').select('min_year').single();
	const minYear: number = Math.min(extent.data?.min_year ?? 1800, settings?.min_year ?? 1800);
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
		tags: (await loadTags(locals.supabase)).filter((t) => t.total_uses > 0)
	};
};
