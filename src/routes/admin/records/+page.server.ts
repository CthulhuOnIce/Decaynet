import { error, fail, redirect } from '@sveltejs/kit';
import { loadTags, requirePermission } from '$lib/server/db';
import { FormError, dbMessage, str } from '$lib/server/forms';
import { createPageSource, librarySources, madeSource, type MadeSource } from '$lib/server/sources';
import { NEW_SOURCE } from '$lib/sources';
import { parseFuzzyDate } from '$lib/time';
import { CONTEXT_DEFAULTS, CONFLICTS, MODES, gridQuery, readGrid, type ChangeSet, type GridRow, type RecordsContext } from '$lib/records';
import { SET_COOKIE, SET_COOKIE_OPTS } from '$lib/server/records';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ parent, locals, url, cookies }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, `/login?next=${encodeURIComponent(url.pathname + url.search)}`);
	if (!perms.includes('manage_records')) error(403, 'Records is for admins (the “Manage records” permission).');

	const grid = readGrid(url.searchParams);
	const [setsRes, sources, tags, views] = await Promise.all([
		locals.supabase.rpc('records_sets', { p_limit: 12 }),
		librarySources(locals.supabase),
		loadTags(locals.supabase),
		locals.supabase.from('records_views').select('*').order('name')
	]);
	const sets = (setsRes.data ?? []) as ChangeSet[];
	const current = sets.find((s) => s.id === cookies.get(SET_COOKIE) && !s.undone_at) ?? null;
	const context: RecordsContext = { ...CONTEXT_DEFAULTS, ...(current?.context ?? {}) };

	// the year the grid shows: the change set's, else ?y=, else this year
	const at = context.at ?? (grid.year ? `${grid.year.padStart(4, '0')}-01-01` : `${new Date().getFullYear()}-01-01`);
	const atP = context.at ? context.at_p : 'year';
	const { data, error: err } = await locals.supabase.rpc('records_grid', { p: { ...gridQuery(grid, at), at_p: atP } });
	if (err) error(500, dbMessage(err));
	const g = data as { total: number; listed: number; rows: GridRow[] };

	return {
		sets,
		current,
		context,
		at,
		atP,
		sources,
		tags,
		grid: { total: g.total ?? 0, listed: g.listed ?? 0, rows: g.rows ?? [] },
		views: (views.data ?? []) as { id: string; name: string; query: string; owner_id: string; shared: boolean }[],
		me: user.id as string,
		params: url.search
	};
};

const failed = (e: unknown) => {
	if (e instanceof FormError) return fail(400, { error: e.message });
	throw e;
};

/** The context bar's fields: the year or range, how edits land, the source, confidence. */
async function contextFromForm(locals: App.Locals, fd: FormData): Promise<{ ctx: RecordsContext; made: MadeSource | null }> {
	const at = parseFuzzyDate(str(fd, 'at'));
	if (!at) throw new FormError('Which year are you working in? (1925, 1920s, May 1925…)');
	const toText = str(fd, 'to');
	const to = toText ? parseFuzzyDate(toText) : null;
	if (toText && !to) throw new FormError('The end year should look like 1930 or the 1930s.');
	const mode = (str(fd, 'mode') ?? 'seen') as RecordsContext['mode'];
	if (!MODES.some((m) => m.id === mode)) throw new FormError('Pick how edits land in time.');
	if (mode === 'only' && !to) throw new FormError('“Only” needs an end year too.');
	const conflict = (str(fd, 'conflict') ?? 'skip') as RecordsContext['conflict'];
	let source = str(fd, 'source_id');
	let made: MadeSource | null = null;
	if (source === NEW_SOURCE) {
		made = await createPageSource(locals.supabase, fd, null);
		source = made.id;
	}
	if (!source && mode !== 'correct') throw new FormError('Pick the source you’re working from: every edit is cited to it.');
	return {
		ctx: {
			at: at.date,
			at_p: at.precision,
			to: to?.date ?? null,
			to_p: to?.precision ?? 'year',
			mode,
			source_id: source || null,
			source_detail: str(fd, 'source_detail'),
			confidence: str(fd, 'confidence') ?? 'probable',
			conflict: CONFLICTS.some((c) => c.id === conflict) ? conflict : 'skip'
		},
		made
	};
}

export const actions: Actions = {
	/** Set the context: the open change set's, or (asked, or none open) a new set's. */
	context: async ({ request, locals, cookies }) => {
		await requirePermission(locals, 'manage_records');
		const fd = await request.formData();
		try {
			const { ctx, made } = await contextFromForm(locals, fd);
			const current = cookies.get(SET_COOKIE);
			const fresh = fd.get('fresh') === '1' || !current;
			const srcTitle = made?.title ?? (ctx.source_id ? (await locals.supabase.from('sources').select('title').eq('id', ctx.source_id).maybeSingle()).data?.title : null);
			const title = str(fd, 'title') ?? [ctx.at?.slice(0, 4), srcTitle].filter(Boolean).join(' · ');
			if (!fresh) {
				const { data, error: err } = await locals.supabase
					.from('change_sets')
					.update({ context: ctx })
					.eq('id', current)
					.is('undone_at', null)
					.select('id')
					.maybeSingle();
				if (err) throw new FormError(dbMessage(err));
				if (data) return { saved: true, newSource: madeSource(made) };
			}
			const { data, error: err } = await locals.supabase.from('change_sets').insert({ title, context: ctx }).select('id').single();
			if (err) throw new FormError(dbMessage(err));
			cookies.set(SET_COOKIE, data.id, SET_COOKIE_OPTS);
			return { saved: true, opened: data.id, newSource: madeSource(made) };
		} catch (e) {
			return failed(e);
		}
	},

	/** Carry on in an earlier change set. */
	switch: async ({ request, locals, cookies }) => {
		await requirePermission(locals, 'manage_records');
		const id = str(await request.formData(), 'set');
		if (!id) {
			cookies.delete(SET_COOKIE, { path: '/admin/records' });
			return { switched: null };
		}
		const { data } = await locals.supabase.from('change_sets').select('id, undone_at').eq('id', id).maybeSingle();
		if (!data || data.undone_at) return fail(400, { error: 'That change set was undone; start a new one.' });
		cookies.set(SET_COOKIE, id, SET_COOKIE_OPTS);
		return { switched: id };
	},

	rename: async ({ request, locals, cookies }) => {
		await requirePermission(locals, 'manage_records');
		const fd = await request.formData();
		const title = (str(fd, 'title') ?? '').slice(0, 200);
		const { error: err } = await locals.supabase.from('change_sets').update({ title }).eq('id', cookies.get(SET_COOKIE) ?? '');
		if (err) return fail(400, { error: dbMessage(err) });
		return { renamed: true };
	},

	/** Keep the grid as it is (filters, columns, sort) under a name, for you or every admin. */
	saveView: async ({ request, locals }) => {
		await requirePermission(locals, 'manage_records');
		const fd = await request.formData();
		const name = (str(fd, 'name') ?? '').slice(0, 120);
		if (!name) return fail(400, { error: 'Give the view a name.' });
		const query = new URLSearchParams(str(fd, 'query') ?? '');
		query.delete('page');
		const { error: err } = await locals.supabase.from('records_views').insert({ name, query: `?${query}`, shared: fd.get('shared') === 'on' });
		if (err) return fail(400, { error: dbMessage(err) });
		return { savedView: name };
	},

	deleteView: async ({ request, locals }) => {
		await requirePermission(locals, 'manage_records');
		const { error: err } = await locals.supabase.from('records_views').delete().eq('id', str(await request.formData(), 'id') ?? '');
		if (err) return fail(400, { error: dbMessage(err) });
		return { deletedView: true };
	},

	/** Undo the open change set as a whole (refused, with what's in the way, if things changed since). */
	undoSet: async ({ request, locals, cookies }) => {
		await requirePermission(locals, 'manage_records');
		const fd = await request.formData();
		const id = str(fd, 'set') ?? cookies.get(SET_COOKIE);
		const { data, error: err } = await locals.supabase.rpc('records_undo', { p_set: id, p_preview: false });
		if (err) return fail(400, { error: dbMessage(err) });
		const r = data as { undone: boolean; changes: number; conflicts: { name: string | null; table: string }[] };
		if (!r.undone) return fail(409, { error: 'Not undone: some of it was changed again since.', conflicts: r.conflicts });
		if (id === cookies.get(SET_COOKIE)) cookies.delete(SET_COOKIE, { path: '/admin/records' });
		return { undoneSet: r.changes };
	}
};
