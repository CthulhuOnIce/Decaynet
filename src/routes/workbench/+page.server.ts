import { fail, redirect } from '@sveltejs/kit';
import { requirePermission } from '$lib/server/db';
import { FormError, dbMessage, fuzzyPair, required, slugify, str } from '$lib/server/forms';
import type { MapLayer } from '$lib/types';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, parent }) => {
	const { user, perms } = await parent();
	if (!user) redirect(303, '/login?next=/workbench');
	if (!perms.includes('edit_content') && !perms.includes('manage_layers') && !perms.includes('bulk_edit'))
		redirect(303, '/');
	const [layers, sources, extent] = await Promise.all([
		locals.supabase.from('map_layers').select('*').order('depicts_from', { nullsFirst: false }),
		locals.supabase.from('sources').select('id, title').order('title'),
		locals.supabase.rpc('timeline_extent')
	]);
	return {
		layers: (layers.data ?? []) as MapLayer[],
		sources: sources.data ?? [],
		minYear: Math.min(extent.data?.min_year ?? 1890, 1890),
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
	/** Save (create or update) a scanned-image overlay pinned by four corners. */
	saveOverlay: wrap(async (fd, locals) => {
		await requirePermission(locals, 'manage_layers');
		const corners = JSON.parse(required(fd, 'corners'));
		if (!Array.isArray(corners) || corners.length !== 4) throw new FormError('Need four corners.');
		const life = fuzzyPair(fd, 'depicts_from', 'depicts_to');
		const row = {
			title: required(fd, 'title', 'Title'),
			kind: 'image',
			image_path: required(fd, 'image_path'),
			corners,
			depicts_from: life.from,
			depicts_to: life.to,
			attribution: str(fd, 'attribution'),
			notes: str(fd, 'notes'),
			default_opacity: Number(str(fd, 'opacity') ?? 0.75),
			source_id: str(fd, 'source_id')
		};
		const id = str(fd, 'id');
		const res = id
			? await locals.supabase.from('map_layers').update(row).eq('id', id).select('id').single()
			: await locals.supabase.from('map_layers').insert(row).select('id').single();
		check(res);
		return { ok: id ? 'Overlay alignment saved.' : 'Overlay created.', layerId: res.data!.id as string };
	}),

	/** Save a traced shape as a new page, or as a dated shape on an existing page. */
	trace: wrap(async (fd, locals) => {
		await requirePermission(locals, 'edit_content');
		const geom = parseGeo(str(fd, 'geojson'));
		const life = fuzzyPair(fd, 'valid_from', 'valid_to');
		const confidence = str(fd, 'confidence') ?? 'probable';
		let entityId = str(fd, 'entity_id');
		let slug: string | null = null;
		if (!entityId) {
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
					lifespan_confidence: confidence
				})
				.select('id, slug')
				.single();
			check(ins);
			entityId = ins.data!.id;
			slug = ins.data!.slug;
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
		return { ok: 'Shape saved.', slug };
	}),

	previewArea: wrap(async (fd, locals) => {
		await requirePermission(locals, 'bulk_edit');
		const area = parseGeo(str(fd, 'geojson'), 'polygon');
		const at = fuzzyPair(fd, 'at', 'at_to').from;
		if (!at) throw new FormError('When did the change happen?');
		const kinds = fd.getAll('kinds').map(String);
		const res = await locals.supabase.rpc('entities_in_area', { p_area: area, p_at: at, p_kinds: kinds.length ? kinds : null });
		check(res);
		return { preview: res.data as { id: string; slug: string; kind: string; name: string; status: string | null }[] };
	}),

	retireArea: wrap(async (fd, locals) => {
		await requirePermission(locals, 'bulk_edit');
		const area = parseGeo(str(fd, 'geojson'), 'polygon');
		const life = fuzzyPair(fd, 'at', 'at_to');
		if (!life.from) throw new FormError('When did the change happen?');
		const ids = fd.getAll('ids').map(String);
		if (!ids.length) throw new FormError('Nothing selected.');
		const res = await locals.supabase.rpc('retire_area', {
			p_area: area,
			p_at: life.from,
			p_precision: life.fromPrecision,
			p_kinds: null,
			p_status: str(fd, 'status') ?? 'demolished',
			p_note: str(fd, 'note'),
			p_source_id: str(fd, 'source_id'),
			p_ids: ids
		});
		check(res);
		return { ok: `Retired ${res.data} feature${res.data === 1 ? '' : 's'}.` };
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
