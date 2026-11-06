import { error, redirect } from '@sveltejs/kit';
import { dbMessage } from '$lib/server/forms';
import { SET_COOKIE } from '$lib/server/records';
import { librarySources } from '$lib/server/sources';
import { FACT_TABLES, type ChangeSet, type FactRow } from '$lib/records';
import type { PageServerLoad } from './$types';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PER = [100, 250, 500];

export const load: PageServerLoad = async ({ parent, locals, url, cookies }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, `/login?next=${encodeURIComponent(url.pathname + url.search)}`);
	if (!perms.includes('manage_records')) error(403, 'Records is for admins (the “Manage records” permission).');
	const u = url.searchParams;
	const table = FACT_TABLES.some((t) => t.id === u.get('table')) ? (u.get('table') as string) : 'entity_states';
	const per = PER.includes(Number(u.get('per'))) ? Number(u.get('per')) : 100;
	const pageNo = Math.max(1, Number(u.get('page')) || 1);
	const year = (k: string) => (/^\d{3,4}$/.test(u.get(k) ?? '') ? Number(u.get(k)) : undefined);
	const q = {
		table,
		ids: (u.get('ids') ?? '').split(',').filter((s) => UUID.test(s)).slice(0, 1000),
		kinds: u.getAll('kind').filter(Boolean),
		uncited: u.get('uncited') === '1',
		confidences: u.getAll('conf').filter(Boolean),
		from_year: year('from'),
		to_year: year('to'),
		text: u.get('text') ?? undefined,
		key: u.get('key') ?? undefined,
		predicate: u.get('predicate') ?? undefined,
		name_type: u.get('name_type') ?? undefined,
		set: UUID.test(u.get('set') ?? '') ? u.get('set') : undefined,
		sort: u.get('sort') ?? 'page',
		limit: per,
		offset: (pageNo - 1) * per
	};
	const [facts, current, sources] = await Promise.all([
		locals.supabase.rpc('records_facts', { p: { ...q, ids: q.ids.length ? q.ids : undefined, kinds: q.kinds.length ? q.kinds : undefined, confidences: q.confidences.length ? q.confidences : undefined } }),
		cookies.get(SET_COOKIE) ? locals.supabase.from('change_sets').select('*').eq('id', cookies.get(SET_COOKIE) as string).is('undone_at', null).maybeSingle() : Promise.resolve({ data: null }),
		librarySources(locals.supabase)
	]);
	if (facts.error) error(500, dbMessage(facts.error));
	const f = facts.data as { total: number; rows: FactRow[] };
	return { q, per, pageNo, total: f.total, rows: f.rows, current: (current.data ?? null) as ChangeSet | null, sources };
};
