import { fail, redirect } from '@sveltejs/kit';
import { entityBySlug, requireEditor } from '$lib/server/db';
import { renderArticle } from '$lib/server/markdown';
import { FormError, dbMessage, str } from '$lib/server/forms';
import { createPageSource, sourceOptions } from '$lib/server/sources';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals }) => {
	const { user } = await locals.safeGetSession();
	if (!user) redirect(303, `/login?next=/e/${params.slug}/edit`);
	const entity = await entityBySlug(locals.supabase, params.slug);
	const [{ data: article }, sources] = await Promise.all([
		locals.supabase.from('articles').select('*').eq('entity_id', entity.id).maybeSingle(),
		sourceOptions(locals.supabase, entity.id)
	]);
	return { entity, article, sources };
};

export const actions: Actions = {
	preview: async ({ request, locals }) => {
		const fd = await request.formData();
		return { preview: await renderArticle(locals.supabase, str(fd, 'body') ?? '') };
	},
	/** Create a source for this page from the editor's Cite panel (the article text is untouched). */
	addSource: async ({ request, params, locals }) => {
		await requireEditor(locals);
		const entity = await entityBySlug(locals.supabase, params.slug);
		try {
			return { newSource: await createPageSource(locals.supabase, await request.formData(), entity.id, 'cs_') };
		} catch (e) {
			if (e instanceof FormError) return fail(400, { sourceError: e.message });
			throw e;
		}
	},
	save: async ({ request, params, locals }) => {
		await requireEditor(locals);
		const entity = await entityBySlug(locals.supabase, params.slug);
		const fd = await request.formData();
		const body = String(fd.get('body') ?? '');
		const { error } = await locals.supabase.rpc('save_article', {
			p_entity: entity.id,
			p_body: body,
			p_summary: str(fd, 'summary'),
			p_status: str(fd, 'status')
		});
		if (error) return fail(400, { error: dbMessage(error), body });

		if (fd.has('locked')) {
			const locked = fd.getAll('locked').includes('on');
			await locals.supabase.from('articles').update({ locked }).eq('entity_id', entity.id);
		}
		redirect(303, `/e/${params.slug}`);
	}
};
