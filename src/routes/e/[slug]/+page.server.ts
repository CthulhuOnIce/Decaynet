import { error } from '@sveltejs/kit';
import { entityBySlug } from '$lib/server/db';
import { renderArticle } from '$lib/server/markdown';
import { yearToDate } from '$lib/time';
import type { EntitySnapshot, EntityTag, RelationRow, SourceRow, Space, TimelineRow } from '$lib/types';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, url, locals }) => {
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

	// Footnotes: every source cited by any fact on this page
	const sourceIds = [...new Set([...tl.map((r) => r.source_id), ...rels.map((r) => r.source_id), mediaItem.data?.source_id].filter(Boolean))] as string[];
	const { data: sources } = sourceIds.length
		? await sb.from('sources').select('*').in('id', sourceIds).order('title')
		: { data: [] };

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
		html: article.data?.body ? await renderArticle(sb, article.data.body) : '',
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
		sources: (sources ?? []) as SourceRow[]
	};
};
