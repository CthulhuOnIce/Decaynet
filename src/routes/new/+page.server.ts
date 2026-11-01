import { fail, redirect } from '@sveltejs/kit';
import { requireEditor } from '$lib/server/db';
import { FormError, dbMessage, fuzzyPair, required, slugify, str } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, url }) => {
	const { user } = await locals.safeGetSession();
	if (!user) redirect(303, `/login?next=${encodeURIComponent(url.pathname + url.search)}`);
	return {
		preset: {
			kind: url.searchParams.get('kind') ?? 'building',
			slug: url.searchParams.get('slug') ?? '',
			name: (url.searchParams.get('slug') ?? '').replace(/-/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())
		}
	};
};

export const actions: Actions = {
	default: async ({ request, locals }) => {
		await requireEditor(locals);
		const fd = await request.formData();
		const values = Object.fromEntries([...fd.entries()].filter(([, v]) => typeof v === 'string'));
		try {
			const name = required(fd, 'name', 'Name');
			const kind = required(fd, 'kind', 'Kind');
			const slug = slugify(str(fd, 'slug') ?? name);
			if (!slug) throw new FormError('Could not make a slug from that name.');
			const life = fuzzyPair(fd, 'exists_from', 'exists_to');

			const { data: entity, error } = await locals.supabase
				.from('entities')
				.insert({
					kind,
					slug,
					name,
					summary: str(fd, 'summary'),
					exists_from: life.from,
					exists_from_precision: life.fromPrecision,
					exists_to: life.to,
					exists_to_precision: life.toPrecision,
					lifespan_confidence: life.approximate ? 'approximate' : 'probable',
					is_private: fd.get('is_private') === 'on'
				})
				.select('id, slug')
				.single();
			if (error) throw new FormError(dbMessage(error));

			if (kind === 'event') {
				const r = await locals.supabase.from('event_details').insert({ entity_id: entity.id, event_type: str(fd, 'event_type') ?? 'other' });
				if (r.error) throw new FormError(dbMessage(r.error));
			}

			// Optional point dropped on the map
			const geojson = str(fd, 'geojson_text') ?? str(fd, 'geojson');
			if (geojson) {
				const r = await locals.supabase.rpc('add_geometry', {
					p_entity: entity.id,
					p_geojson: JSON.parse(geojson),
					p_role: 'shape',
					p_valid_from: life.from,
					p_valid_from_precision: life.fromPrecision,
					p_confidence: 'approximate'
				});
				if (r.error) throw new FormError(`Page created, but the shape failed: ${dbMessage(r.error)}`);
			}

			// Initial condition, if given
			const status = str(fd, 'status');
			if (status) {
				await locals.supabase.from('entity_states').insert({
					entity_id: entity.id,
					status,
					valid_from: life.from,
					valid_from_precision: life.fromPrecision
				});
			}
			redirect(303, `/e/${entity.slug}/facts`);
		} catch (e) {
			if (e instanceof FormError) return fail(400, { error: e.message, values });
			if (e instanceof SyntaxError) return fail(400, { error: 'Invalid GeoJSON.', values });
			throw e;
		}
	}
};
