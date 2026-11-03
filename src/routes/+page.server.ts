import { loadSettings, loadTags } from '$lib/server/db';
import type { ChronologyRow } from '$lib/types';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	const sb = locals.supabase;
	const [extent, years, settings, tags] = await Promise.all([
		sb.rpc('timeline_extent'),
		// things happening per year, for the slider's histogram (migration 0033)
		sb.rpc('chronology_years', { p_from: '1800-01-01' }),
		loadSettings(sb),
		loadTags(sb)
	]);

	const minYear: number = Math.min(extent.data?.min_year ?? 1800, settings.min_year ?? 1800);
	const maxYear: number = extent.data?.max_year ?? new Date().getFullYear();

	const density = new Array(maxYear - minYear + 1).fill(0);
	const add = (y: number, n: number) => {
		if (y >= minYear && y <= maxYear) density[y - minYear] += n;
	};
	if (!years.error) for (const r of (years.data ?? []) as { year: number; n: number }[]) add(r.year, r.n);
	else {
		// a database before 0033: count from the chronology itself
		const { data } = await sb.rpc('chronology', { p_from: '1800-01-01', p_limit: 5000 });
		for (const row of (data ?? []) as ChronologyRow[]) add(Number(row.at.slice(0, 4)), 1);
	}

	return {
		minYear,
		maxYear,
		density,
		tags: tags.filter((t) => t.total_uses > 0)
	};
};
