import { fail } from '@sveltejs/kit';
import { loadTags, requireEditor } from '$lib/server/db';
import { dbMessage, slugify, str } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => ({ tags: await loadTags(locals.supabase) });

export const actions: Actions = {
	create: async ({ request, locals }) => {
		await requireEditor(locals);
		const fd = await request.formData();
		const label = str(fd, 'label');
		if (!label) return fail(400, { error: 'Name the tag.' });
		const parentId = str(fd, 'parent_id');
		let facet = str(fd, 'facet');
		if (parentId) {
			const { data } = await locals.supabase.from('tags').select('facet').eq('id', parentId).single();
			facet = data?.facet ?? facet;
		}
		if (!facet) return fail(400, { error: 'Pick a facet for a top-level tag.' });
		const { error } = await locals.supabase.from('tags').insert({
			label,
			facet,
			parent_id: parentId,
			slug: slugify(str(fd, 'slug') ?? label),
			description: str(fd, 'description')
		});
		if (error) return fail(400, { error: dbMessage(error) });
		return { ok: true };
	}
};
