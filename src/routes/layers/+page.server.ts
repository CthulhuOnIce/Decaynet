import { fail } from '@sveltejs/kit';
import { requireEditor } from '$lib/server/db';
import { FormError, dbMessage, required, str } from '$lib/server/forms';
import { parseFuzzyDate, precisionEndInclusive } from '$lib/time';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	const { data } = await locals.supabase.from('map_layers').select('*').order('depicts_from', { nullsFirst: false });
	return { layers: data ?? [] };
};

export const actions: Actions = {
	create: async ({ request, locals }) => {
		await requireEditor(locals);
		const fd = await request.formData();
		try {
			const url = required(fd, 'tile_url', 'Tile URL');
			if (!/^https:\/\/.+\{z\}.+\{x\}.+\{y\}/.test(url))
				throw new FormError('Tile URL must be https and contain {z}, {x} and {y}.');
			const from = parseFuzzyDate(str(fd, 'depicts_from'));
			const to = parseFuzzyDate(str(fd, 'depicts_to'));
			const bounds = str(fd, 'bounds')?.split(',').map(Number);
			if (bounds && (bounds.length !== 4 || !bounds.every(Number.isFinite)))
				throw new FormError('Bounds are west,south,east,north.');
			const { error } = await locals.supabase.from('map_layers').insert({
				title: required(fd, 'title', 'Title'),
				tile_url: url,
				tile_size: Number(str(fd, 'tile_size') ?? 256),
				attribution: str(fd, 'attribution'),
				depicts_from: from?.date ?? null,
				depicts_to: to ? precisionEndInclusive(to.date!, to.precision) : null,
				min_zoom: Number(str(fd, 'min_zoom') ?? 0),
				max_zoom: Number(str(fd, 'max_zoom') ?? 22),
				bounds: bounds ?? null,
				default_opacity: Number(str(fd, 'default_opacity') ?? 0.75)
			});
			if (error) throw new FormError(dbMessage(error));
			return { ok: true };
		} catch (e) {
			if (e instanceof Error) return fail(400, { error: e.message });
			throw e;
		}
	},
	toggle: async ({ request, locals }) => {
		await requireEditor(locals);
		const fd = await request.formData();
		const { error } = await locals.supabase
			.from('map_layers')
			.update({ enabled: fd.get('enabled') === 'true' })
			.eq('id', String(fd.get('id')));
		if (error) return fail(400, { error: dbMessage(error) });
	},
	remove: async ({ request, locals }) => {
		await requireEditor(locals);
		const fd = await request.formData();
		const { error } = await locals.supabase.from('map_layers').delete().eq('id', String(fd.get('id')));
		if (error) return fail(400, { error: dbMessage(error) });
	}
};
