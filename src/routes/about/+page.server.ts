import { renderArticle } from '$lib/server/markdown';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ parent, locals }) => {
	const { settings } = await parent();
	return { aboutHtml: settings.about ? await renderArticle(locals.supabase, settings.about) : '' };
};
