import { fail, redirect } from '@sveltejs/kit';
import { entityBySlug, loadTags, requireEditor } from '$lib/server/db';
import { FormError, dbMessage, fuzzyPair, required, slugify, str, temporalFromForm } from '$lib/server/forms';
import type { RelationRow, Space } from '$lib/types';
import type { Actions, PageServerLoad, RequestEvent } from './$types';

/** Component tables that share the temporal header and can be edited generically. */
const COMPONENTS = ['entity_names', 'entity_states', 'entity_attributes', 'addresses', 'relations', 'entity_geometries', 'entity_tags'] as const;
type Component = (typeof COMPONENTS)[number];
const isComponent = (t: string | null): t is Component => !!t && (COMPONENTS as readonly string[]).includes(t);

export const load: PageServerLoad = async ({ params, locals }) => {
	const { user } = await locals.safeGetSession();
	if (!user) redirect(303, `/login?next=/e/${params.slug}/facts`);
	const sb = locals.supabase;
	const entity = await entityBySlug(sb, params.slug);
	const id = entity.id;

	const [names, states, attributes, addresses, relations, geoms, sources, event, media, entityTags, tags, spaces] = await Promise.all([
		sb.from('entity_names').select('*').eq('entity_id', id).order('valid_from', { nullsFirst: true }),
		sb.from('entity_states').select('*, lifecycle_statuses(label, color)').eq('entity_id', id).order('valid_from', { nullsFirst: true }),
		sb.from('entity_attributes').select('*, attribute_keys(label, unit)').eq('entity_id', id).order('key'),
		sb.from('addresses').select('*, street:entities!addresses_street_id_fkey(id, name, slug)').eq('entity_id', id).order('valid_from', { nullsFirst: true }),
		sb.rpc('entity_relations', { p_entity: id }),
		sb.from('entity_geometries_geojson').select('*').eq('entity_id', id).order('valid_from', { nullsFirst: true }),
		sb.from('sources').select('id, title').order('title'),
		sb.from('event_details').select('*').eq('entity_id', id).maybeSingle(),
		sb.from('media_items').select('*').eq('entity_id', id).maybeSingle(),
		sb.from('entity_tags').select('*').eq('entity_id', id).order('valid_from', { nullsFirst: true }),
		loadTags(sb),
		['building', 'site'].includes(entity.kind)
			? sb.rpc('building_spaces', { p_building: id, p_at: null })
			: Promise.resolve({ data: [] })
	]);

	return {
		entity,
		names: names.data ?? [],
		states: states.data ?? [],
		attributes: attributes.data ?? [],
		addresses: addresses.data ?? [],
		relations: (relations.data ?? []) as RelationRow[],
		geoms: geoms.data ?? [],
		sources: sources.data ?? [],
		event: event.data,
		media: media.data,
		entityTags: entityTags.data ?? [],
		spaces: (spaces.data ?? []) as Space[],
		tags
	};
};

/** Wraps an action: auth, entity lookup, friendly errors. */
function action(fn: (ctx: { fd: FormData; entityId: string; event: RequestEvent }) => Promise<unknown>) {
	return async (event: RequestEvent) => {
		await requireEditor(event.locals);
		const entity = await entityBySlug(event.locals.supabase, event.params.slug);
		const fd = await event.request.formData();
		const section = str(fd, 'section') ?? 'general';
		try {
			await fn({ fd, entityId: entity.id, event });
		} catch (e) {
			if (e instanceof FormError) return fail(400, { section, error: e.message });
			throw e;
		}
		return { section, ok: true };
	};
}

const check = (res: { error: { message: string; code?: string } | null }) => {
	if (res.error) throw new FormError(dbMessage(res.error));
};

/** "office=Mayor, floor=2" or JSON → qualifiers object */
function parseQualifiers(s: string | null): Record<string, string | number> {
	if (!s) return {};
	if (s.trim().startsWith('{')) {
		try {
			return JSON.parse(s);
		} catch {
			throw new FormError('Qualifiers are not valid JSON.');
		}
	}
	const out: Record<string, string | number> = {};
	for (const part of s.split(',')) {
		const [k, ...rest] = part.split('=');
		if (!k?.trim() || !rest.length) throw new FormError('Qualifiers look like: office=Mayor, ward=3');
		const v = rest.join('=').trim();
		out[k.trim()] = /^-?\d+(\.\d+)?$/.test(v) ? Number(v) : v;
	}
	return out;
}

export const actions: Actions = {
	updateEntity: action(async ({ fd, entityId, event }) => {
		const life = fuzzyPair(fd, 'exists_from', 'exists_to');
		const conf = str(fd, 'lifespan_confidence') ?? 'probable';
		check(
			await event.locals.supabase
				.from('entities')
				.update({
					name: required(fd, 'name', 'Name'),
					summary: str(fd, 'summary'),
					exists_from: life.from,
					exists_from_precision: life.fromPrecision,
					exists_to: life.to,
					exists_to_precision: life.toPrecision,
					lifespan_confidence: life.approximate && conf === 'probable' ? 'approximate' : conf
				})
				.eq('id', entityId)
		);
		const eventType = str(fd, 'event_type');
		if (eventType) {
			check(await event.locals.supabase.from('event_details').upsert({ entity_id: entityId, event_type: eventType }));
		}
	}),

	addName: action(async ({ fd, entityId, event }) => {
		check(
			await event.locals.supabase.from('entity_names').insert({
				entity_id: entityId,
				name: required(fd, 'name', 'Name'),
				name_type: str(fd, 'name_type') ?? 'official',
				...temporalFromForm(fd)
			})
		);
	}),

	addState: action(async ({ fd, entityId, event }) => {
		check(
			await event.locals.supabase.from('entity_states').insert({
				entity_id: entityId,
				status: required(fd, 'status', 'Status'),
				...temporalFromForm(fd)
			})
		);
	}),

	addAttribute: action(async ({ fd, entityId, event }) => {
		const key = required(fd, 'key', 'Attribute');
		const raw = required(fd, 'value', 'Value');
		const { data: ak } = await event.locals.supabase.from('attribute_keys').select('value_type').eq('id', key).single();
		let value: unknown = raw;
		if (ak?.value_type === 'number' || ak?.value_type === 'year') {
			const n = Number(raw.replace(/[$,\s]/g, ''));
			if (!Number.isFinite(n)) throw new FormError(`“${raw}” is not a number.`);
			value = n;
		} else if (ak?.value_type === 'boolean') value = /^(y|yes|true|1)$/i.test(raw);
		check(
			await event.locals.supabase.from('entity_attributes').insert({ entity_id: entityId, key, value, ...temporalFromForm(fd) })
		);
	}),

	addAddress: action(async ({ fd, entityId, event }) => {
		const street = str(fd, 'street_id');
		const rawAddress = str(fd, 'raw_address');
		if (!street && !rawAddress) throw new FormError('Pick a street or type the address as written in the source.');
		check(
			await event.locals.supabase.from('addresses').insert({
				entity_id: entityId,
				street_id: street,
				house_number: str(fd, 'house_number'),
				unit: str(fd, 'unit'),
				postal_code: str(fd, 'postal_code'),
				raw_address: rawAddress,
				...temporalFromForm(fd)
			})
		);
	}),

	addRelation: action(async ({ fd, entityId, event }) => {
		const other = required(fd, 'other_id', 'The other page');
		if (other === entityId) throw new FormError('A page cannot relate to itself.');
		const reversed = str(fd, 'direction') === 'in';
		check(
			await event.locals.supabase.from('relations').insert({
				subject_id: reversed ? other : entityId,
				object_id: reversed ? entityId : other,
				predicate: required(fd, 'predicate', 'Relationship'),
				qualifiers: parseQualifiers(str(fd, 'qualifiers')),
				...temporalFromForm(fd)
			})
		);
	}),

	addGeometry: action(async ({ fd, entityId, event }) => {
		const text = str(fd, 'geojson_text') ?? str(fd, 'geojson');
		if (!text) throw new FormError('Draw a shape on the map (or paste GeoJSON).');
		let geom: { type?: string; geometry?: unknown };
		try {
			geom = JSON.parse(text);
		} catch {
			throw new FormError('That GeoJSON could not be parsed.');
		}
		if (geom.type === 'Feature') geom = geom.geometry as typeof geom;
		const t = temporalFromForm(fd);
		check(
			await event.locals.supabase.rpc('add_geometry', {
				p_entity: entityId,
				p_geojson: geom,
				p_role: str(fd, 'role') ?? 'shape',
				p_valid_from: t.valid_from,
				p_valid_from_precision: t.valid_from_precision,
				p_valid_to: t.valid_to,
				p_valid_to_precision: t.valid_to_precision,
				p_confidence: t.confidence,
				p_source_id: t.source_id,
				p_source_detail: t.source_detail,
				p_note: t.note
			})
		);
	}),

	/** Tag with an existing tag, or create a new sub-trait under a parent and tag with that. */
	addTag: action(async ({ fd, entityId, event }) => {
		const sb = event.locals.supabase;
		let tagId = str(fd, 'tag_id');
		const newLabel = str(fd, 'new_label');
		if (newLabel) {
			const parentId = str(fd, 'new_parent_id');
			let facet = str(fd, 'new_facet');
			if (parentId) {
				const { data: parent } = await sb.from('tags').select('facet').eq('id', parentId).single();
				facet = parent?.facet ?? facet;
			}
			if (!facet) throw new FormError('Pick a facet or a parent tag for the new trait.');
			const { data: created, error } = await sb
				.from('tags')
				.insert({ facet, parent_id: parentId, label: newLabel, slug: slugify(newLabel) })
				.select('id')
				.single();
			if (error) throw new FormError(dbMessage(error));
			tagId = created.id;
		}
		if (!tagId) throw new FormError('Choose a tag, or name a new one.');
		check(await sb.from('entity_tags').insert({ entity_id: entityId, tag_id: tagId, ...temporalFromForm(fd) }));
	}),

	/** Draw a space (storefront, suite, hall) inside this building's footprint. */
	addSpace: action(async ({ fd, entityId, event }) => {
		const geo = str(fd, 'geojson_text') ?? str(fd, 'geojson');
		if (!geo) throw new FormError('Draw the space as a polygon inside the footprint.');
		let geom: { type?: string; geometry?: unknown };
		try {
			geom = JSON.parse(geo);
		} catch {
			throw new FormError('That GeoJSON could not be parsed.');
		}
		if (geom.type === 'Feature') geom = geom.geometry as typeof geom;
		const life = fuzzyPair(fd, 'valid_from', 'valid_to');
		const floor = str(fd, 'floor');
		check(
			await event.locals.supabase.rpc('add_space', {
				p_building: entityId,
				p_name: required(fd, 'space_name', 'Space name'),
				p_geojson: geom,
				p_floor: floor == null ? null : Number(floor),
				p_unit_label: str(fd, 'unit_label'),
				p_from: life.from,
				p_from_precision: life.fromPrecision,
				p_to: life.to,
				p_to_precision: life.toPrecision
			})
		);
	}),

	/** Every component shares the temporal header, so one action edits them all. */
	updateFact: action(async ({ fd, event }) => {
		const table = str(fd, 'table');
		if (!isComponent(table)) throw new FormError('Unknown fact type.');
		check(await event.locals.supabase.from(table).update(temporalFromForm(fd)).eq('id', required(fd, 'id')));
	}),

	deleteFact: action(async ({ fd, event }) => {
		const table = str(fd, 'table');
		if (!isComponent(table)) throw new FormError('Unknown fact type.');
		const res = await event.locals.supabase.from(table).delete().eq('id', required(fd, 'id')).select('id');
		check(res);
		if (!res.data?.length) throw new FormError('Not deleted: only moderators or the person who added a fact can remove it.');
	}),

	deleteEntity: async ({ locals, params }) => {
		await requireEditor(locals);
		const entity = await entityBySlug(locals.supabase, params.slug);
		const res = await locals.supabase.from('entities').delete().eq('id', entity.id).select('id');
		if (res.error || !res.data?.length)
			return fail(403, { section: 'danger', error: res.error ? dbMessage(res.error) : 'Only moderators or the creator can delete a page.' });
		redirect(303, '/browse');
	}
};
