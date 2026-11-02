import { fail, redirect } from '@sveltejs/kit';
import { entityBySlug, requirePermission } from '$lib/server/db';
import { dbMessage, str } from '$lib/server/forms';
import { dbFailure, isMissingFunction } from '$lib/server/schema';
import type { Actions, PageServerLoad } from './$types';

interface Item {
	what: string;
	label: string;
	why?: 'place' | 'kind' | 'unique';
}
interface DuplicatePreview {
	blocked?: string;
	from: string;
	from_label: string;
	to: string;
	to_label: string;
	name: string;
	article: boolean;
	sources: number;
	/** link between the copy and the original (occupant ↔ place) */
	tie: { reading: string; copy_is_subject: boolean } | null;
	event: boolean;
	copied: Item[];
	left: Item[];
}

export const load: PageServerLoad = async ({ params, locals, url }) => {
	await requirePermission(locals, 'edit_content');
	const entity = await entityBySlug(locals.supabase, params.slug);
	const to = url.searchParams.get('to') ?? '';
	let preview: DuplicatePreview | null = null;
	if (to) {
		const { data, error } = await locals.supabase.rpc('duplicate_as_kind_preview', { p_entity: entity.id, p_kind: to });
		if (error) dbFailure(error, 'Duplicating a page as another kind');
		preview = data as DuplicatePreview | null;
	}
	return { entity, to, preview };
};

export const actions: Actions = {
	duplicate: async ({ request, params, locals }) => {
		await requirePermission(locals, 'edit_content');
		const entity = await entityBySlug(locals.supabase, params.slug);
		const fd = await request.formData();
		const { data, error } = await locals.supabase.rpc('duplicate_as_kind', {
			p_entity: entity.id,
			p_kind: str(fd, 'kind') ?? '',
			p_name: str(fd, 'name')
		});
		if (error) return fail(isMissingFunction(error) ? 503 : 400, { error: isMissingFunction(error) ? 'The database is behind this version of the app: an admin has to run the migrate step.' : dbMessage(error) });
		redirect(303, `/e/${(data as { slug: string }).slug}?copied_from=${encodeURIComponent(params.slug)}`);
	}
};
