import { error, redirect } from '@sveltejs/kit';
import { SET_COOKIE, logNames } from '$lib/server/records';
import { TABLE_LABELS, type LogRow } from '$lib/records';
import type { PageServerLoad } from './$types';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PER = 200;

/** Everything anyone changed, newest first: by table, kind of change, person, page, change set, date. */
export const load: PageServerLoad = async ({ parent, locals, url, cookies }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, `/login?next=${encodeURIComponent(url.pathname + url.search)}`);
	if (!perms.includes('manage_records')) error(403, 'Records is for admins (the “Manage records” permission).');
	const u = url.searchParams;
	const f = {
		table: Object.keys(TABLE_LABELS).includes(u.get('table') ?? '') ? (u.get('table') as string) : '',
		op: ['INSERT', 'UPDATE', 'DELETE'].includes(u.get('op') ?? '') ? (u.get('op') as string) : '',
		actor: UUID.test(u.get('actor') ?? '') ? (u.get('actor') as string) : '',
		page: UUID.test(u.get('page_id') ?? '') ? (u.get('page_id') as string) : '',
		set: UUID.test(u.get('set') ?? '') ? (u.get('set') as string) : '',
		since: /^\d{4}-\d{2}-\d{2}$/.test(u.get('since') ?? '') ? (u.get('since') as string) : '',
		until: /^\d{4}-\d{2}-\d{2}$/.test(u.get('until') ?? '') ? (u.get('until') as string) : ''
	};
	const pageNo = Math.max(1, Number(u.get('p')) || 1);
	let q = locals.supabase
		.from('change_log')
		.select('id, table_name, op, row_id, entity_id, actor_id, old_data, new_data, created_at, change_set_id', { count: 'exact' });
	if (f.table) q = q.eq('table_name', f.table);
	if (f.op) q = q.eq('op', f.op);
	if (f.actor) q = q.eq('actor_id', f.actor);
	if (f.page) q = q.eq('entity_id', f.page);
	if (f.set) q = q.eq('change_set_id', f.set);
	if (f.since) q = q.gte('created_at', f.since);
	if (f.until) q = q.lt('created_at', `${f.until}T23:59:59.999Z`);
	const [log, people] = await Promise.all([
		q.order('id', { ascending: false }).range((pageNo - 1) * PER, pageNo * PER - 1),
		locals.supabase.from('profiles').select('id, display_name, role').order('display_name').limit(500)
	]);
	const rows = (log.data ?? []) as (LogRow & { actor_id: string | null; change_set_id: string | null })[];
	const pageName = f.page ? ((await locals.supabase.from('entities').select('name').eq('id', f.page).maybeSingle()).data?.name ?? null) : null;
	return {
		f,
		pageName,
		rows,
		total: log.count ?? rows.length,
		pageNo,
		per: PER,
		people: Object.fromEntries(((people.data ?? []) as { id: string; display_name: string }[]).map((p) => [p.id, p.display_name])),
		hasSet: !!cookies.get(SET_COOKIE),
		...(await logNames(locals.supabase, rows))
	};
};
