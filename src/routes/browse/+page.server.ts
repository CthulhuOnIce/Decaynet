import { loadTags } from '$lib/server/db';
import type { PageServerLoad } from './$types';

const PAGE = 60;

export const load: PageServerLoad = async ({ url, locals }) => {
	const kind = url.searchParams.get('kind') ?? '';
	const status = url.searchParams.get('status') ?? '';
	const article = url.searchParams.get('article') ?? '';
	const sort = url.searchParams.get('sort') ?? 'name';
	const page = Math.max(1, Number(url.searchParams.get('page')) || 1);
	const tag = url.searchParams.get('tag') ?? '';
	const tags = await loadTags(locals.supabase);

	let q = locals.supabase.from('entity_cards').select('*', { count: 'exact' });
	if (kind) q = q.eq('kind', kind);
	if (status) q = q.eq('current_status', status);
	if (article) q = q.eq('article_status', article);
	if (tag) {
		const { data: tagged } = await locals.supabase.rpc('entities_tagged', { p_tag: tag, p_limit: 5000 });
		q = q.in('id', [...new Set((tagged ?? []).map((r: { id: string }) => r.id))]);
	}
	q =
		sort === 'recent'
			? q.order('updated_at', { ascending: false })
			: sort === 'oldest'
				? q.order('exists_from', { ascending: true, nullsFirst: false })
				: q.order('name');
	const { data, count, error } = await q.range((page - 1) * PAGE, page * PAGE - 1);

	return {
		rows: data ?? [],
		count: count ?? 0,
		error: error?.message ?? null,
		filters: { kind, status, article, sort, tag },
		tags,
		page,
		pages: Math.max(1, Math.ceil((count ?? 0) / PAGE))
	};
};
