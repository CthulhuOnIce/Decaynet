import { error } from '@sveltejs/kit';
import { loadTags } from '$lib/server/db';
import { yearToDate } from '$lib/time';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, url, locals }) => {
	const tags = await loadTags(locals.supabase);
	const tag = tags.find((t) => t.slug === params.slug);
	if (!tag) error(404, `No tag “${params.slug}”.`);
	const y = Number(url.searchParams.get('y')) || null;

	const { data: rows, error: err } = await locals.supabase.rpc('entities_tagged', {
		p_tag: tag.slug,
		p_at: y ? yearToDate(y) : null
	});
	if (err) error(500, err.message);

	// Ancestors (breadcrumb) and direct children (sub-traits)
	const byId = Object.fromEntries(tags.map((t) => [t.id, t]));
	const ancestors = [];
	for (let p = tag.parent_id; p; p = byId[p]?.parent_id ?? null) ancestors.unshift(byId[p]);
	const children = tags.filter((t) => t.parent_id === tag.id);

	return { tag, ancestors, children, year: y, rows: rows ?? [] };
};
