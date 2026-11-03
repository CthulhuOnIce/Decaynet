import { fail } from '@sveltejs/kit';
import { queueArchive } from '$lib/server/archive';
import { requireEditor } from '$lib/server/db';
import { FormError, dbMessage, required, str } from '$lib/server/forms';
import { parseFuzzyDate } from '$lib/time';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	const [sources, cited] = await Promise.all([
		locals.supabase.from('sources').select('*, page:entities!sources_entity_id_fkey(slug, name)').order('title'),
		locals.supabase.from('facts').select('source_id').not('source_id', 'is', null)
	]);
	const counts: Record<string, number> = {};
	for (const f of cited.data ?? []) counts[f.source_id] = (counts[f.source_id] ?? 0) + 1;
	return { sources: sources.data ?? [], counts };
};

export const actions: Actions = {
	create: async ({ request, locals }) => {
		await requireEditor(locals);
		const fd = await request.formData();
		try {
			const published = parseFuzzyDate(str(fd, 'published_on'));
			const archiveUrl = str(fd, 'archive_url');
			const { data, error } = await locals.supabase.from('sources').insert({
				title: required(fd, 'title', 'Title'),
				kind: str(fd, 'kind') ?? 'other',
				author: str(fd, 'author'),
				publisher: str(fd, 'publisher'),
				published_on: published?.date ?? null,
				published_precision: published?.precision ?? 'year',
				url: str(fd, 'url'),
				archive_url: archiveUrl,
				repository: str(fd, 'repository'),
				call_number: str(fd, 'call_number'),
				notes: str(fd, 'notes')
			}).select('id, url').single();
			if (error) throw new FormError(dbMessage(error));
			if (data.url && !archiveUrl) queueArchive(data.id, locals.supabase);
			return { ok: true };
		} catch (e) {
			if (e instanceof FormError || e instanceof Error) return fail(400, { error: e.message });
			throw e;
		}
	}
};
