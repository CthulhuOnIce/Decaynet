import { fail, redirect } from '@sveltejs/kit';
import { requireEditor } from '$lib/server/db';
import { FormError, dbMessage, fuzzyPair, geometryFromForm, required, slugify, str } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, url }) => {
	const { user } = await locals.safeGetSession();
	if (!user) redirect(303, `/login?next=${encodeURIComponent(url.pathname + url.search)}`);
	// One media flow: files and external media are added through the uploader.
	if (url.searchParams.get('kind') === 'media') {
		const title = url.searchParams.get('name') ?? '';
		redirect(303, `/media/new${title ? `?title=${encodeURIComponent(title)}` : ''}`);
	}
	const slug = url.searchParams.get('slug') ?? '';
	const latParam = url.searchParams.get('lat');
	const lonParam = url.searchParams.get('lon');
	const lat = latParam === null ? NaN : Number(latParam);
	const lon = lonParam === null ? NaN : Number(lonParam);
	const point =
		Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180
			? { type: 'Point' as const, coordinates: [lon, lat] as [number, number] }
			: null;
	return {
		preset: {
			kind: url.searchParams.get('kind') ?? 'building',
			slug,
			name:
				url.searchParams.get('name') ??
				slug.replace(/-/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()),
			address: url.searchParams.get('address') ?? '',
			point
		}
	};
};

export const actions: Actions = {
	default: async ({ request, locals }) => {
		await requireEditor(locals);
		const fd = await request.formData();
		const values = Object.fromEntries([...fd.entries()].filter(([, v]) => typeof v === 'string'));
		try {
			// read a pasted shape first, so a bad one doesn't leave a half-made page
			const geojson = geometryFromForm(fd);
			const name = required(fd, 'name', 'Name');
			const kind = required(fd, 'kind', 'Kind');
			// Media pages need a file/URL, so they belong to the uploader.
			if (kind === 'media') redirect(303, `/media/new?title=${encodeURIComponent(name)}`);
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
			if (geojson) {
				const r = await locals.supabase.rpc('add_geometry', {
					p_entity: entity.id,
					p_geojson: geojson,
					p_role: 'shape',
					p_valid_from: life.from,
					p_valid_from_precision: life.fromPrecision,
					p_confidence: 'approximate'
				});
				if (r.error) throw new FormError(`Page created, but the shape failed: ${dbMessage(r.error)}`);
			}

			// Address carried over from the search box ("create a page at 577 Washington St")
			const addressRaw = str(fd, 'address_raw');
			if (addressRaw) {
				const r = await locals.supabase.from('addresses').insert({
					entity_id: entity.id,
					raw_address: addressRaw,
					valid_from: life.from,
					valid_from_precision: life.fromPrecision,
					confidence: life.approximate ? 'approximate' : 'probable'
				});
				if (r.error) throw new FormError(`Page created, but the address failed: ${dbMessage(r.error)}`);
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
