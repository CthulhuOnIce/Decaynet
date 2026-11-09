import { fail, redirect } from '@sveltejs/kit';
import { newPagesPrivate, requirePermission } from '$lib/server/db';
import { FormError, dbMessage, fuzzyPair, required, slugify, str } from '$lib/server/forms';
import { discardSource, librarySources, madeSource, resolveInlineSource, type MadeSource } from '$lib/server/sources';
import { parseFuzzyDate } from '$lib/time';
import type { Actions, PageServerLoad } from './$types';

/** The bulk year box: "1958", "May 1958", "1950s"…; an unreadable date is a form error, not a crash. */
function bulkDate(fd: FormData) {
	try {
		return parseFuzzyDate(str(fd, 'at'));
	} catch (e) {
		throw new FormError((e as Error).message);
	}
}

/** A bulk action on the selection, citing the source picked (if any) on what it adds. */
function bulk(locals: App.Locals, fd: FormData, action: string, ids: string[], at: { date: string | null; precision: string }, value: string | null = null) {
	return locals.supabase.rpc('bulk_pages', {
		p_action: action,
		p_ids: ids,
		p_at: at.date,
		p_precision: at.precision,
		p_value: value,
		p_note: str(fd, 'note'),
		p_source: str(fd, 'source_id'),
		p_detail: str(fd, 'source_detail')
	});
}

interface BulkResult {
	done: number;
	skipped: { id: string; name: string; slug: string; reason: string }[];
	/** rows it added that got the source picked */
	cited?: number;
}

export const load: PageServerLoad = async ({ locals, parent }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, '/login?next=/workbench');
	if (!perms.includes('edit_content') && !perms.includes('bulk_edit')) redirect(303, '/');
	const [sources, extent] = await Promise.all([
		librarySources(locals.supabase),
		locals.supabase.rpc('timeline_extent')
	]);
	return {
		sources,
		minYear: extent.data?.min_year ?? 1800,
		maxYear: extent.data?.max_year ?? new Date().getFullYear()
	};
};

const parseGeo = (text: string | null, what = 'shape') => {
	if (!text) throw new FormError(`Draw a ${what} first.`);
	try {
		const g = JSON.parse(text);
		return g.type === 'Feature' ? g.geometry : g;
	} catch {
		throw new FormError('Invalid GeoJSON.');
	}
};

function wrap<T>(fn: (fd: FormData, locals: App.Locals) => Promise<T>) {
	return async ({ request, locals }: { request: Request; locals: App.Locals }) => {
		const fd = await request.formData();
		const tool = str(fd, 'tool') ?? 'general';
		try {
			return { tool, ...(await fn(fd, locals)) };
		} catch (e) {
			if (e instanceof FormError) return fail(400, { tool, error: e.message });
			throw e;
		}
	};
}

const check = (res: { error: { message: string; code?: string } | null }) => {
	if (res.error) throw new FormError(dbMessage(res.error));
};

export const actions: Actions = {
	/** Save a traced shape as a new page, or as a dated shape on an existing page. */
	trace: wrap(async (fd, locals) => {
		await requirePermission(locals, 'edit_content');
		const geom = parseGeo(str(fd, 'geojson'));
		const life = fuzzyPair(fd, 'valid_from', 'valid_to');
		const confidence = str(fd, 'confidence') ?? 'probable';
		let entityId = str(fd, 'entity_id');
		let slug: string | null = null;
		let made: MadeSource | null = null;
		// "New source…" belongs to the page the shape goes on
		if (entityId) made = await resolveInlineSource(locals.supabase, fd, entityId);
		else {
			const name = required(fd, 'name', 'Name');
			const kind = required(fd, 'kind', 'Kind');
			const ins = await locals.supabase
				.from('entities')
				.insert({
					kind,
					name,
					slug: `${slugify(name)}-${crypto.randomUUID().slice(0, 4)}`,
					exists_from: life.from,
					exists_from_precision: life.fromPrecision,
					exists_to: life.to,
					exists_to_precision: life.toPrecision,
					lifespan_confidence: confidence,
					is_private: await newPagesPrivate(locals.supabase)
				})
				.select('id, slug')
				.single();
			check(ins);
			entityId = ins.data!.id;
			slug = ins.data!.slug;
			made = await resolveInlineSource(locals.supabase, fd, entityId!);
			const status = str(fd, 'status');
			if (status)
				check(
					await locals.supabase.from('entity_states').insert({
						entity_id: entityId,
						status,
						valid_from: life.from,
						valid_from_precision: life.fromPrecision,
						source_id: str(fd, 'source_id'),
						confidence
					})
				);
		}
		check(
			await locals.supabase.rpc('add_geometry', {
				p_entity: entityId,
				p_geojson: geom,
				p_role: str(fd, 'role') ?? 'footprint',
				p_valid_from: life.from,
				p_valid_from_precision: life.fromPrecision,
				p_valid_to: life.to,
				p_valid_to_precision: life.toPrecision,
				p_confidence: confidence,
				p_source_id: str(fd, 'source_id'),
				p_source_detail: str(fd, 'source_detail'),
				p_note: str(fd, 'note')
			})
		);
		if (!slug) slug = (await locals.supabase.from('entities').select('slug').eq('id', entityId).single()).data?.slug ?? null;
		// the form keeps its fields for the next shape: it switches to this source instead of making another
		return { ok: 'Shape saved.', slug, newSource: madeSource(made) };
	}),

	/** Selected pages: gone by a year (e.g. missing from that year's aerial). */
	bulkGone: wrap(async (fd, locals) => {
		await requirePermission(locals, 'edit_content');
		const ids = fd.getAll('ids').map(String).filter(Boolean);
		if (!ids.length) throw new FormError('Select some buildings first.');
		const at = bulkDate(fd);
		if (!at?.date) throw new FormError('Gone by when? Enter a year, like 1958.');
		const res = await bulk(locals, fd, 'gone', ids, at, str(fd, 'status') ?? 'demolished');
		check(res);
		return { bulk: { ...(res.data as BulkResult), action: 'gone' as const, at: str(fd, 'at') } };
	}),

	/** Selected pages: in a condition from a year (e.g. abandoned in that year's aerial). */
	bulkCondition: wrap(async (fd, locals) => {
		await requirePermission(locals, 'edit_content');
		const ids = fd.getAll('ids').map(String).filter(Boolean);
		if (!ids.length) throw new FormError('Select some buildings first.');
		const at = bulkDate(fd);
		if (!at?.date) throw new FormError('From when? Enter a year, like 1958.');
		const status = str(fd, 'condition');
		if (!status) throw new FormError('Pick a condition.');
		const res = await bulk(locals, fd, 'condition', ids, at, status);
		check(res);
		return { bulk: { ...(res.data as BulkResult), action: 'condition' as const, at: str(fd, 'at'), status } };
	}),

	/** Selected pages marked gone that a later aerial shows still standing. */
	bulkStanding: wrap(async (fd, locals) => {
		await requirePermission(locals, 'edit_content');
		const ids = fd.getAll('ids').map(String).filter(Boolean);
		if (!ids.length) throw new FormError('Select some buildings first.');
		const at = bulkDate(fd);
		if (!at?.date) throw new FormError('Still standing in which year?');
		const res = await bulk(locals, fd, 'standing', ids, at);
		check(res);
		return { bulk: { ...(res.data as BulkResult), action: 'standing' as const, at: str(fd, 'at') } };
	}),

	/** Selected pages not built yet in a year (missing from an aerial older than the one they were plotted from). */
	bulkNotYet: wrap(async (fd, locals) => {
		await requirePermission(locals, 'edit_content');
		const ids = fd.getAll('ids').map(String).filter(Boolean);
		if (!ids.length) throw new FormError('Select some buildings first.');
		const at = bulkDate(fd);
		if (!at?.date) throw new FormError('Not seen yet in which year? Enter one, like 1955.');
		const res = await bulk(locals, fd, 'notyet', ids, at);
		check(res);
		const r = res.data as BulkResult & { starts: string };
		return { bulk: { ...r, action: 'notyet' as const, at: str(fd, 'at') } };
	}),

	/** Selected pages: an official name from a year (e.g. the label on that year's sanborn sheet). */
	bulkName: wrap(async (fd, locals) => {
		await requirePermission(locals, 'edit_content');
		const ids = fd.getAll('ids').map(String).filter(Boolean);
		if (!ids.length) throw new FormError('Select some buildings first.');
		const at = bulkDate(fd);
		if (!at?.date) throw new FormError('Named from when? Enter a year, like 1925.');
		const name = required(fd, 'name', 'Name');
		const res = await bulk(locals, fd, 'name', ids, at, name);
		check(res);
		return { bulk: { ...(res.data as BulkResult), action: 'name' as const, at: str(fd, 'at'), name: name.replace(/\s+/g, ' ').trim() } };
	}),

	/** Shift (and turn) the selected pages' shapes, as shown in a year, where they always were. */
	moveShapes: wrap(async (fd, locals) => {
		await requirePermission(locals, 'edit_content');
		const ids = fd.getAll('ids').map(String).filter(Boolean);
		if (!ids.length) throw new FormError('Select some buildings first.');
		const n = (k: string) => {
			const v = Number(str(fd, k));
			if (!Number.isFinite(v)) throw new FormError('Drag the shapes to where they belong first.');
			return v;
		};
		const res = await locals.supabase.rpc('move_shapes', {
			p_ids: ids,
			p_at: required(fd, 'at'),
			p_from_lon: n('from_lon'),
			p_from_lat: n('from_lat'),
			p_to_lon: n('to_lon'),
			p_to_lat: n('to_lat'),
			p_angle: n('angle'),
			p_spaces: str(fd, 'spaces') !== '0'
		});
		check(res);
		return { moved: res.data as { shapes: number; pages: number; spaces: number } };
	}),

	/** A new shape for one page from a year: the one shown then ends there. */
	redraw: wrap(async (fd, locals) => {
		await requirePermission(locals, 'edit_content');
		const entity = required(fd, 'entity_id');
		const at = bulkDate(fd);
		if (!at?.date) throw new FormError('From which year? Enter one, like 1958.');
		const made = await resolveInlineSource(locals.supabase, fd, entity);
		const res = await locals.supabase.rpc('redraw_shape', {
			p_entity: entity,
			p_at: at.date,
			p_precision: at.precision,
			p_geojson: parseGeo(str(fd, 'geojson')),
			p_confidence: str(fd, 'confidence') ?? 'probable',
			p_source_id: str(fd, 'source_id'),
			p_note: str(fd, 'note')
		});
		if (res.error) await discardSource(locals.supabase, made);
		check(res);
		const r = res.data as { id: string; ended: string | null; replaced: boolean };
		return {
			ok: r.replaced
				? `Shape redrawn (it already started in ${str(fd, 'at')}).`
				: r.ended
					? `New shape from ${str(fd, 'at')}; the old one ends then.`
					: `Shape added from ${str(fd, 'at')}.`,
			redrawn: true,
			newSource: madeSource(made)
		};
	}),

	import: wrap(async (fd, locals) => {
		await requirePermission(locals, 'bulk_edit');
		let fc: unknown;
		try {
			fc = JSON.parse(required(fd, 'fc', 'GeoJSON'));
		} catch (e) {
			if (e instanceof FormError) throw e;
			throw new FormError('That file is not valid JSON.');
		}
		const life = fuzzyPair(fd, 'valid_from', 'valid_to');
		const res = await locals.supabase.rpc('import_features', {
			p_fc: fc,
			p_kind: required(fd, 'kind'),
			p_name_prop: str(fd, 'name_prop') ?? 'name',
			p_from: life.from,
			p_from_precision: life.fromPrecision,
			p_to: life.to,
			p_to_precision: life.toPrecision,
			p_from_prop: str(fd, 'from_prop'),
			p_to_prop: str(fd, 'to_prop'),
			p_status: str(fd, 'status'),
			p_confidence: str(fd, 'confidence') ?? 'approximate',
			p_source_id: str(fd, 'source_id'),
			p_role: str(fd, 'role') ?? 'shape'
		});
		check(res);
		return { ok: `Imported ${res.data} feature${res.data === 1 ? '' : 's'}.` };
	})
};
