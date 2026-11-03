import { error, fail } from '@sveltejs/kit';
import { invalidateSiteData, requirePermission } from '$lib/server/db';
import { dbMessage, str } from '$lib/server/forms';
import { VOCABS, type VocabTable } from '$lib/vocabSchema';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, url }) => {
	await requirePermission(locals, 'moderate');
	const tableName = url.searchParams.get('t') ?? VOCABS[0].table;
	const def = VOCABS.find((v) => v.table === tableName);
	if (!def) error(404, 'Unknown vocabulary');
	const { data, error: err } = await locals.supabase.from(def.table).select('*').order('sort').order('id');
	if (err) error(500, err.message);
	return { table: def.table, rows: (data ?? []) as Record<string, unknown>[] };
};

function readRow(def: VocabTable, fd: FormData) {
	const row: Record<string, unknown> = {};
	for (const f of def.fields) {
		const v = str(fd, f.name);
		if (f.type === 'bool') row[f.name] = fd.get(f.name) === 'on';
		else if (f.type === 'number') row[f.name] = v == null ? 0 : Number(v);
		else if (f.type === 'list') row[f.name] = v ? v.split(',').map((x) => x.trim()).filter(Boolean) : null;
		else if (f.type === 'select' && v === '') row[f.name] = null;
		else row[f.name] = v;
	}
	return row;
}

const defOf = (fd: FormData) => {
	const def = VOCABS.find((v) => v.table === str(fd, 'table'));
	if (!def) throw error(400, 'Unknown vocabulary');
	return def;
};

export const actions: Actions = {
	save: async ({ request, locals }) => {
		await requirePermission(locals, 'moderate');
		const fd = await request.formData();
		const def = defOf(fd);
		const { error: err } = await locals.supabase.from(def.table).update(readRow(def, fd)).eq('id', str(fd, 'id'));
		invalidateSiteData();
		if (err) return fail(400, { error: dbMessage(err) });
		return { ok: `Saved “${str(fd, 'id')}”.` };
	},
	add: async ({ request, locals }) => {
		await requirePermission(locals, 'moderate');
		const fd = await request.formData();
		const def = defOf(fd);
		const id = (str(fd, 'id') ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
		if (!id) return fail(400, { error: 'Give the new entry an id (letters, numbers, underscores).' });
		const row = readRow(def, fd);
		if (!row.label) return fail(400, { error: 'Give the new entry a label.' });
		// sensible defaults for required columns
		if (def.table === 'entity_kinds') row.plural ??= `${row.label}s`;
		if (def.table === 'relation_types') row.inverse_label ??= `${row.label} (reverse)`;
		for (const f of def.fields) if (f.type === 'color' && !row[f.name]) row[f.name] = '#c2562b';
		const { error: err } = await locals.supabase.from(def.table).insert({ id, ...row });
		invalidateSiteData();
		if (err) return fail(400, { error: dbMessage(err) });
		return { ok: `Added “${id}”.` };
	},
	delete: async ({ request, locals }) => {
		await requirePermission(locals, 'moderate');
		const fd = await request.formData();
		const def = defOf(fd);
		const id = str(fd, 'id')!;
		if (def.core.includes(id)) return fail(400, { error: `“${id}” is used by the application; relabel it instead of deleting.` });
		const { error: err } = await locals.supabase.from(def.table).delete().eq('id', id);
		invalidateSiteData();
		if (err)
			return fail(400, {
				error: err.code === '23503' ? `“${id}” is still in use by some pages or facts. Change those first.` : dbMessage(err)
			});
		return { ok: `Deleted “${id}”.` };
	}
};
