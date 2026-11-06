import { error, json } from '@sveltejs/kit';
import { requirePermission } from '$lib/server/db';
import { dbMessage } from '$lib/server/forms';
import { SET_COOKIE } from '$lib/server/records';
import { gridQuery, readGrid, type WriteItem, type WriteResult, type WriteSummary } from '$lib/records';
import type { RequestHandler } from './$types';

type Body =
	| { op: 'write'; items: WriteItem[]; preview?: boolean }
	| { op: 'undoLast'; after: number }
	| { op: 'pages'; ids: string[]; patch: Record<string, unknown> }
	| { op: 'delete'; ids: string[]; expect: number; spaces?: boolean }
	| { op: 'ids'; search: string; at: string }
	| { op: 'makeTenant'; ids: string[]; match: string; org: string | null; newName: string | null; opts: Record<string, unknown>; preview?: boolean }
	| { op: 'tagSuggestions'; ids: string[] }
	| { op: 'spaces'; id: string }
	| { op: 'addSpaces'; building: string; rows: Record<string, unknown>[]; preview?: boolean }
	| { op: 'progress'; progress: Record<string, unknown> };

/** Records' edits, as JSON: write (or preview) items, undo the last edit, page fields, delete, list ids. */
export const POST: RequestHandler = async ({ request, locals, cookies }) => {
	await requirePermission(locals, 'manage_records');
	const body = (await request.json()) as Body;
	const set = cookies.get(SET_COOKIE) ?? null;
	const sb = locals.supabase;
	const needSet = () => {
		if (!set) error(400, 'Set the year and the source you’re working from first (the bar at the top).');
		return set;
	};

	if (body.op === 'ids') {
		const g = readGrid(new URLSearchParams(body.search));
		const { data, error: err } = await sb.rpc('records_grid', { p: { ...gridQuery(g, body.at), ids_only: true } });
		if (err) error(400, dbMessage(err));
		return json(data);
	}

	if (body.op === 'write') {
		const id = needSet();
		if (!Array.isArray(body.items) || !body.items.length) error(400, 'Nothing to change.');
		if (body.items.length > 5000) error(400, 'That’s more than 5,000 changes at once; split it up.');
		// addresses typed as text: find the street page
		const skipped: WriteResult[] = [];
		const texts = body.items
			.map((it, i) => ({ it, i }))
			.filter(({ it }) => it.field === 'address' && (typeof it.value === 'string' || (it.value && typeof it.value === 'object' && 'text' in (it.value as object))));
		if (texts.length) {
			const { data, error: err } = await sb.rpc('records_addresses', {
				p_texts: texts.map(({ it }) => (typeof it.value === 'string' ? it.value : String((it.value as { text: string }).text))),
				p_street: (texts[0].it.value as { street_id?: string } | null)?.street_id ?? null
			});
			if (err) error(400, dbMessage(err));
			const parsed = data as ({ street_id?: string; house_number?: string; street?: string; unit?: string } | null)[];
			texts.forEach(({ it }, k) => {
				const p = parsed[k];
				const unit = typeof it.value === 'object' && it.value ? (it.value as { unit?: string }).unit : undefined;
				if (p && p.street && !p.street_id) {
					skipped.push({ entity: it.entity, field: it.field, op: it.op ?? 'set', outcome: 'skipped', reason: `no street page called “${p.street}”` });
					it.value = undefined;
				} else it.value = p ? { street_id: p.street_id, house_number: p.house_number, unit } : null;
			});
		}
		const items = body.items.filter((it) => it.value !== undefined || it.op === 'remove');
		let result: WriteSummary = { items: [], after: null, changed: 0, cited: 0, already: 0, skipped: 0, conflict: 0 };
		if (items.length) {
			const { data, error: err } = await sb.rpc('records_write', { p_set: id, p_items: items, p_preview: !!body.preview });
			if (err) error(400, dbMessage(err));
			result = data as WriteSummary;
		}
		result.items = [...result.items, ...skipped];
		result.skipped += skipped.length;
		return json(result);
	}

	if (body.op === 'undoLast') {
		const { data, error: err } = await sb.rpc('records_undo', { p_set: needSet(), p_preview: false, p_after: body.after });
		if (err) error(400, dbMessage(err));
		return json(data);
	}

	if (body.op === 'pages') {
		const { data, error: err } = await sb.rpc('records_set_pages', { p_set: needSet(), p_ids: body.ids, p_patch: body.patch });
		if (err) error(400, dbMessage(err));
		return json(data);
	}

	if (body.op === 'delete') {
		const { data, error: err } = await sb.rpc('records_delete', { p_set: needSet(), p_ids: body.ids, p_expect: body.expect, p_spaces: !!body.spaces });
		if (err) error(400, dbMessage(err));
		return json(data);
	}

	if (body.op === 'makeTenant') {
		const { data, error: err } = await sb.rpc('records_make_tenant', {
			p_set: needSet(),
			p_ids: body.ids,
			p_match: body.match,
			p_org: body.org || null,
			p_new: body.org ? null : { name: body.newName, kind: 'organization' },
			p_opts: body.opts,
			p_preview: !!body.preview
		});
		if (err) error(400, dbMessage(err));
		return json(data);
	}

	if (body.op === 'tagSuggestions') {
		const { data, error: err } = await sb.rpc('records_tag_suggestions', { p_set: needSet(), p_ids: body.ids });
		if (err) error(400, dbMessage(err));
		return json(data);
	}

	if (body.op === 'spaces') {
		const { data, error: err } = await sb.rpc('interior_spaces', { p_entity: body.id });
		if (err) error(400, dbMessage(err));
		return json(data);
	}

	if (body.op === 'addSpaces') {
		const { data, error: err } = await sb.rpc('records_add_spaces', { p_set: needSet(), p_building: body.building, p_rows: body.rows, p_preview: !!body.preview });
		if (err) error(400, dbMessage(err));
		return json(data);
	}

	if (body.op === 'progress') {
		const { error: err } = await sb.from('change_sets').update({ progress: body.progress }).eq('id', needSet());
		if (err) error(400, dbMessage(err));
		return json({ ok: true });
	}

	error(400, 'Unknown request');
};
