import { error, fail } from '@sveltejs/kit';
import { entityBySlug, requirePermission } from '$lib/server/db';
import { queuePageSources } from '$lib/server/archive';
import { dbMessage } from '$lib/server/forms';
import { renderArticle } from '$lib/server/markdown';
import { extractCitations } from '$lib/sources';
import { yearToDate } from '$lib/time';
import type { EntitySnapshot, EntityTag, RelationRow, SourceRow, Space, TimelineRow } from '$lib/types';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, url, locals, parent }) => {
	const sb = locals.supabase;
	const entity = await entityBySlug(sb, params.slug);
	const nowYear = new Date().getFullYear();
	const yParam = Number(url.searchParams.get('y'));
	const year = Number.isInteger(yParam) && yParam > 0 ? yParam : nowYear;

	const [article, snapshot, timeline, relations, geoms, mediaItem, eventDetail, statusEvents, tags] = await Promise.all([
		sb.from('articles').select('*, article_statuses(label, color, description)').eq('entity_id', entity.id).maybeSingle(),
		sb.rpc('entity_snapshot', { p_entity: entity.id, p_at: yearToDate(year) }),
		sb.rpc('entity_timeline', { p_entity: entity.id }),
		sb.rpc('entity_relations', { p_entity: entity.id }),
		sb.from('entity_geometries_geojson').select('*').eq('entity_id', entity.id).order('valid_from', { nullsFirst: true }),
		sb.from('media_items').select('*').eq('entity_id', entity.id).maybeSingle(),
		sb.from('event_details').select('*, event_types(label, color)').eq('entity_id', entity.id).maybeSingle(),
		sb.from('article_status_events').select('*').eq('entity_id', entity.id).order('created_at', { ascending: false }).limit(10),
		sb.rpc('tags_at', { p_entity: entity.id, p_at: null })
	]);
	for (const r of [snapshot, timeline, relations, geoms]) if (r.error) error(500, r.error.message);

	const rels = (relations.data ?? []) as RelationRow[];
	const { data: spaces } = ['building', 'site'].includes(entity.kind)
		? await sb.rpc('building_spaces', { p_building: entity.id, p_at: yearToDate(year) })
		: { data: [] };
	const tl = (timeline.data ?? []) as TimelineRow[];

	// Media that depicts this entity, for the gallery
	const mediaIds = rels.filter((r) => r.other_kind === 'media' && r.predicate === 'depicts').map((r) => r.other_id);
	const { data: gallery } = mediaIds.length
		? await sb.from('entities').select('id, slug, name, exists_from, exists_from_precision, media_items(*)').in('id', mediaIds).order('exists_from', { nullsFirst: false })
		: { data: [] };

	// Footnotes: every source cited by any fact on this page or in its article
	const body = article.data?.body ?? '';
	const sourceIds = [
		...new Set([...tl.map((r) => r.source_id), ...rels.map((r) => r.source_id), mediaItem.data?.source_id, ...extractCitations(body)].filter(Boolean))
	] as string[];
	const { data: sources } = sourceIds.length
		? await sb.from('sources').select('*').in('id', sourceIds).order('title')
		: { data: [] };
	const footnote = Object.fromEntries((sources ?? []).map((s, i) => [s.id as string, i + 1]));

	// For people who can clean up timelines: how many fixes this page has waiting
	const { perms } = await parent();
	const timelineFixes = (perms ?? []).includes('clean_timelines')
		? (((await sb.rpc('timeline_plan', { p_entity: entity.id })).data ?? []) as { op: string; default: boolean }[]).filter((f) => f.op !== 'note' && f.default).length
		: 0;

	const geomFeatures: GeoJSON.Feature[] = (geoms.data ?? []).map((g) => ({
		type: 'Feature',
		geometry: g.geojson,
		properties: {
			id: g.id,
			role: g.role,
			current:
				(!g.valid_from || g.valid_from <= yearToDate(year)) &&
				(!g.valid_to || Number(g.valid_to.slice(0, 4)) >= year)
		}
	}));

	return {
		entity,
		year,
		article: article.data,
		html: body ? await renderArticle(sb, body, footnote) : '',
		snapshot: snapshot.data as EntitySnapshot,
		timeline: tl,
		relations: rels,
		geomFeatures,
		media: mediaItem.data,
		event: eventDetail.data,
		statusEvents: statusEvents.data ?? [],
		gallery: gallery ?? [],
		tags: (tags.data ?? []) as EntityTag[],
		spaces: (spaces ?? []) as Space[],
		sources: (sources ?? []) as SourceRow[],
		timelineFixes
	};
};

export const actions: Actions = {
	/** Publish a private page, or take a public one back to private. */
	visibility: async ({ request, locals, params }) => {
		await requirePermission(locals, 'edit_content');
		const entity = await entityBySlug(locals.supabase, params.slug);
		const fd = await request.formData();
		const makePrivate = fd.get('private') === 'true';
		const { error: err } = await locals.supabase.from('entities').update({ is_private: makePrivate }).eq('id', entity.id);
		if (err) return fail(400, { error: dbMessage(err) });
		if (!makePrivate) await queuePageSources(locals.supabase, entity.id); // held back while it was private
		return { ok: makePrivate ? 'Page is now private.' : 'Published: the page is now public.' };
	},
	/** Moderators: lock or unlock the article without opening the editor. */
	lock: async ({ request, locals, params }) => {
		await requirePermission(locals, 'moderate');
		const entity = await entityBySlug(locals.supabase, params.slug);
		const locked = (await request.formData()).get('locked') === 'true';
		const { error: err } = await locals.supabase.from('articles').update({ locked }).eq('entity_id', entity.id);
		if (err) return fail(400, { error: dbMessage(err) });
		return { ok: locked ? 'Article locked: only moderators can edit it.' : 'Article unlocked.' };
	}
};
