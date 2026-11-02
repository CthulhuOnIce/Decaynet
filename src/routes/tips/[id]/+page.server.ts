import { error, fail, redirect } from '@sveltejs/kit';
import { env as priv } from '$env/dynamic/private';
import { env as pub } from '$env/dynamic/public';
import { newPagesPrivate, requirePermission } from '$lib/server/db';
import { dbMessage, required, slugify, str } from '$lib/server/forms';
import { parseFuzzyDate } from '$lib/time';
import type { Actions, PageServerLoad } from './$types';

type TipImage = { path: string; name: string; mime: string; size: number };

// Signed URLs are built from the internal Supabase URL (e.g. http://kong:8000); browsers need the public one.
function publicUrl(signed: string) {
	const internal = priv.SUPABASE_INTERNAL_URL?.replace(/\/$/, '');
	const pubBase = pub.PUBLIC_SUPABASE_URL?.replace(/\/$/, '');
	return internal && pubBase && signed.startsWith(internal) ? pubBase + signed.slice(internal.length) : signed;
}

export const load: PageServerLoad = async ({ params, locals }) => {
	await requirePermission(locals, 'review_tips');
	if (!/^[0-9a-f-]{36}$/i.test(params.id)) error(404, 'Not found');
	const { data: tip } = await locals.supabase.from('tips_view').select('*').eq('id', params.id).maybeSingle();
	if (!tip) error(404, 'Tip not found');
	const images = (tip.images ?? []) as TipImage[];
	let urls: Record<string, string> = {};
	if (images.length) {
		const { data } = await locals.supabase.storage.from('tips').createSignedUrls(images.map((i) => i.path), 3600);
		urls = Object.fromEntries((data ?? []).filter((d) => d.signedUrl && d.path).map((d) => [d.path!, publicUrl(d.signedUrl as string)]));
	}
	// Other tips from the same source, to spot duplicates and abuse
	const { count: sameSource } = tip.ip_hash
		? await locals.supabase.from('tips').select('id', { count: 'exact', head: true }).eq('ip_hash', tip.ip_hash)
		: { count: 0 };
	return { tip, images, urls, sameSource: sameSource ?? 0 };
};

async function setFields(locals: App.Locals, id: string, fields: Record<string, unknown>) {
	const { user } = await locals.safeGetSession();
	return locals.supabase
		.from('tips')
		.update({ ...fields, reviewer_id: user?.id, reviewed_at: new Date().toISOString() })
		.eq('id', id);
}

export const actions: Actions = {
	status: async ({ request, locals, params }) => {
		await requirePermission(locals, 'review_tips');
		const fd = await request.formData();
		const { error: err } = await setFields(locals, params.id, {
			status: required(fd, 'status'),
			reviewer_notes: str(fd, 'reviewer_notes')
		});
		if (err) return fail(400, { error: dbMessage(err) });
		return { ok: 'Saved.' };
	},
	link: async ({ request, locals, params }) => {
		await requirePermission(locals, 'review_tips');
		const fd = await request.formData();
		const id = str(fd, 'entity_id');
		if (!id) return fail(400, { error: 'Pick a page.' });
		const { error: err } = await setFields(locals, params.id, { resulting_entity_id: id, status: 'accepted' });
		if (err) return fail(400, { error: dbMessage(err) });
		return { ok: 'Linked. Now add the facts on that page.' };
	},
	create: async ({ request, locals, params }) => {
		await requirePermission(locals, 'edit_content');
		const fd = await request.formData();
		const name = str(fd, 'name');
		if (!name) return fail(400, { error: 'Name the new page.' });
		const kind = str(fd, 'kind') ?? 'building';
		const { data: tip } = await locals.supabase.from('tips').select('location').eq('id', params.id).single();
		const { data: entity, error: err } = await locals.supabase
			.from('entities')
			.insert({
				kind,
				name,
				slug: `${slugify(name)}-${crypto.randomUUID().slice(0, 4)}`,
				summary: 'Created from an anonymous tip.',
				is_private: await newPagesPrivate(locals.supabase)
			})
			.select('id, slug')
			.single();
		if (err) return fail(400, { error: dbMessage(err) });
		if (tip?.location) {
			const { data: geo } = await locals.supabase.from('tips_view').select('location_geojson').eq('id', params.id).single();
			if (geo?.location_geojson)
				await locals.supabase.rpc('add_geometry', { p_entity: entity.id, p_geojson: geo.location_geojson, p_role: 'point', p_confidence: 'speculative', p_note: 'Location from an anonymous tip' });
		}
		await setFields(locals, params.id, { resulting_entity_id: entity.id, status: 'accepted' });
		redirect(303, `/e/${entity.slug}/facts`);
	},
	promote: async ({ request, locals, params }) => {
		await requirePermission(locals, 'upload_media');
		const fd = await request.formData();
		const path = required(fd, 'path');
		if (!path.startsWith(`${params.id}/`)) return fail(400, { error: 'That image does not belong to this tip.' });
		const title = str(fd, 'title') ?? 'Photo from a tip';
		const captured = (() => {
			try {
				return parseFuzzyDate(str(fd, 'captured'));
			} catch {
				return null;
			}
		})();

		const { data: blob, error: dl } = await locals.supabase.storage.from('tips').download(path);
		if (dl || !blob) return fail(400, { error: `Could not read the image: ${dl?.message}` });
		const ext = path.split('.').pop() ?? 'jpg';
		const mediaPath = `${new Date().getFullYear()}/tip-${crypto.randomUUID()}.${ext}`;
		const up = await locals.supabase.storage.from('media').upload(mediaPath, blob, { contentType: blob.type || undefined });
		if (up.error) return fail(400, { error: dbMessage(up.error) });

		const { data: entity, error: err } = await locals.supabase
			.from('entities')
			.insert({
				kind: 'media',
				name: title,
				slug: `${slugify(title)}-${crypto.randomUUID().slice(0, 6)}`,
				summary: 'Contributed through an anonymous tip.',
				exists_from: captured?.date ?? null,
				exists_from_precision: captured?.precision ?? 'year',
				lifespan_confidence: 'speculative'
			})
			.select('id, slug')
			.single();
		if (err) return fail(400, { error: dbMessage(err) });
		await locals.supabase.from('media_items').insert({
			entity_id: entity.id,
			media_type: 'photo',
			storage_path: mediaPath,
			mime_type: blob.type,
			rights: str(fd, 'rights') ?? 'Submitted anonymously; rights unverified'
		});
		const depicts = str(fd, 'depicts_id');
		if (depicts)
			await locals.supabase.from('relations').insert({
				subject_id: entity.id,
				predicate: 'depicts',
				object_id: depicts,
				valid_from: captured?.date ?? null,
				valid_from_precision: captured?.precision ?? 'year',
				valid_to: captured?.date ?? null,
				valid_to_precision: captured?.precision ?? 'year',
				confidence: 'speculative',
				note: `From tip ${params.id}`
			});
		return { ok: `Added to media as “${title}”.`, mediaSlug: entity.slug };
	},
	delete: async ({ locals, params }) => {
		await requirePermission(locals, 'moderate');
		const { data: tip } = await locals.supabase.from('tips').select('images').eq('id', params.id).single();
		const paths = ((tip?.images ?? []) as TipImage[]).map((i) => i.path);
		if (paths.length) await locals.supabase.storage.from('tips').remove(paths);
		const { error: err } = await locals.supabase.from('tips').delete().eq('id', params.id);
		if (err) return fail(400, { error: dbMessage(err) });
		redirect(303, '/tips');
	}
};
