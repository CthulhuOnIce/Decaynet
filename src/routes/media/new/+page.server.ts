import { fail, redirect } from '@sveltejs/kit';
import { loadTags, newPagesPrivate, requireEditor } from '$lib/server/db';
import { FormError, dbMessage, fuzzyPair, required, slugify, str, temporalFromForm } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

const MEDIA_TYPES = ['photo', 'postcard', 'map', 'aerial', 'document', 'newspaper', 'video', 'audio', 'drawing', 'other'];

export const load: PageServerLoad = async ({ locals, url }) => {
	const { user } = await locals.safeGetSession();
	if (!user) redirect(303, `/login?next=${encodeURIComponent(url.pathname + url.search)}`);
	const depictsSlug = url.searchParams.get('depicts');
	const [{ data: depicts }, { data: sources }] = await Promise.all([
		depictsSlug
			? locals.supabase.from('entities').select('id, name, slug').eq('slug', depictsSlug).maybeSingle()
			: Promise.resolve({ data: null }),
		locals.supabase.from('sources').select('id, title').order('title')
	]);
	const tags = await loadTags(locals.supabase);
	return { depicts, sources: sources ?? [], mediaTypes: MEDIA_TYPES, userId: user.id, tags };
};

export const actions: Actions = {
	default: async ({ request, locals }) => {
		await requireEditor(locals);
		const fd = await request.formData();
		const sb = locals.supabase;
		try {
			let storagePath = str(fd, 'storage_path');
			// No-JS fallback: the browser normally uploads straight to Storage
			const file = fd.get('file');
			if (!storagePath && file instanceof File && file.size > 0) {
				const ext = file.name.includes('.') ? file.name.split('.').pop()!.toLowerCase() : 'bin';
				storagePath = `${new Date().getFullYear()}/${crypto.randomUUID()}.${ext}`;
				const up = await sb.storage.from('media').upload(storagePath, file, { contentType: file.type || undefined });
				if (up.error) throw new FormError(`Upload failed: ${up.error.message}`);
				fd.set('mime_type', file.type);
			}
			const externalUrl = str(fd, 'external_url');
			if (!storagePath && !externalUrl) throw new FormError('Upload a file or give a URL.');
			if (externalUrl && !/^https?:\/\//.test(externalUrl)) throw new FormError('External URL must start with http(s)://');

			const title = required(fd, 'title', 'Title');
			const captured = fuzzyPair(fd, 'captured', 'captured_to');
			const mediaType = MEDIA_TYPES.includes(str(fd, 'media_type') ?? '') ? str(fd, 'media_type')! : 'photo';

			const base = slugify(`${title} ${captured.from?.slice(0, 4) ?? ''}`) || 'media';
			const slug = `${base}-${crypto.randomUUID().slice(0, 6)}`;

			const { data: entity, error } = await sb
				.from('entities')
				.insert({
					kind: 'media',
					slug,
					name: title,
					summary: str(fd, 'summary'),
					exists_from: captured.from,
					exists_from_precision: captured.fromPrecision,
					lifespan_confidence: captured.approximate ? 'approximate' : 'probable',
					is_private: await newPagesPrivate(sb)
				})
				.select('id, slug')
				.single();
			if (error) throw new FormError(dbMessage(error));

			const sourceId = str(fd, 'source_id');
			const mi = await sb.from('media_items').insert({
				entity_id: entity.id,
				media_type: mediaType,
				storage_path: storagePath,
				external_url: externalUrl,
				mime_type: str(fd, 'mime_type'),
				creator: str(fd, 'creator'),
				rights: str(fd, 'rights'),
				bearing: str(fd, 'bearing') ? Number(str(fd, 'bearing')) % 360 : null,
				source_id: sourceId
			});
			if (mi.error) throw new FormError(dbMessage(mi.error));

			// What it shows, and when. Defaults to the capture date.
			const depicts = str(fd, 'depicts_id');
			if (depicts) {
				const t = temporalFromForm(fd);
				const r = await sb.from('relations').insert({
					subject_id: entity.id,
					predicate: 'depicts',
					object_id: depicts,
					...t,
					valid_from: t.valid_from ?? captured.from,
					valid_from_precision: t.valid_from ? t.valid_from_precision : captured.fromPrecision,
					valid_to: t.valid_to ?? (t.valid_from ? null : captured.from),
					valid_to_precision: t.valid_to ? t.valid_to_precision : captured.fromPrecision,
					source_id: t.source_id ?? sourceId
				});
				if (r.error) throw new FormError(dbMessage(r.error));
			}

			// Tags (subject, topic, era...): apply for as long as the media exists
			const tagIds = fd.getAll('tags').map(String).filter(Boolean);
			if (tagIds.length) {
				const r = await sb.from('entity_tags').insert(tagIds.map((tag_id) => ({ entity_id: entity.id, tag_id })));
				if (r.error) throw new FormError(dbMessage(r.error));
			}

			// Where the camera stood
			const view = str(fd, 'geojson_text') ?? str(fd, 'geojson');
			if (view) {
				const r = await sb.rpc('add_geometry', {
					p_entity: entity.id,
					p_geojson: JSON.parse(view),
					p_role: 'viewpoint',
					p_valid_from: captured.from,
					p_valid_from_precision: captured.fromPrecision,
					p_confidence: 'approximate'
				});
				if (r.error) throw new FormError(dbMessage(r.error));
			}

			redirect(303, `/e/${entity.slug}`);
		} catch (e) {
			if (e instanceof FormError) return fail(400, { error: e.message });
			if (e instanceof SyntaxError) return fail(400, { error: 'Invalid GeoJSON for the viewpoint.' });
			throw e;
		}
	}
};
