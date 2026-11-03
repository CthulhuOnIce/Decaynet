import { error, fail } from '@sveltejs/kit';
import { entityBySlug, requirePermission } from '$lib/server/db';
import { dbMessage } from '$lib/server/forms';
import { renderArticle } from '$lib/server/markdown';
import { extractCitations } from '$lib/sources';
import { yearToDate } from '$lib/time';
import type { EntitySnapshot, EntityTag, RelationRow, SourceRow, Space, TimelineRow } from '$lib/types';
import type { Actions, PageServerLoad } from './$types';

/** Fixes the timeline cleanup would apply by default, leaving out what someone ignored (none before 0032). */
async function waitingFixes(sb: App.Locals['supabase'], id: string): Promise<number> {
	const [plan, ignored] = await Promise.all([sb.rpc('timeline_plan', { p_entity: id }), sb.rpc('timeline_dismissed_keys', { p_entity: id })]);
	const skip = new Set(ignored.error ? [] : ((ignored.data ?? []) as string[]));
	return ((plan.data ?? []) as { key: string; op: string; default: boolean }[]).filter((f) => f.op !== 'note' && f.default && !skip.has(f.key)).length;
}

export const load: PageServerLoad = async ({ params, url, locals, parent }) => {
	const sb = locals.supabase;
	const [entity, { perms }] = await Promise.all([entityBySlug(sb, params.slug), parent()]);
	const nowYear = new Date().getFullYear();
	const yParam = Number(url.searchParams.get('y'));
	const year = Number.isInteger(yParam) && yParam > 0 ? yParam : nowYear;
	const canClean = (perms ?? []).includes('clean_timelines');

	// Everything that only needs the page, in one round
	const [article, snapshot, timeline, relations, geoms, mediaItem, eventDetail, statusEvents, tags, spacesRes, timelineFixes] = await Promise.all([
		sb.from('articles').select('*, article_statuses(label, color, description)').eq('entity_id', entity.id).maybeSingle(),
		sb.rpc('entity_snapshot', { p_entity: entity.id, p_at: yearToDate(year) }),
		sb.rpc('entity_timeline', { p_entity: entity.id }),
		sb.rpc('entity_relations', { p_entity: entity.id }),
		sb.from('entity_geometries_geojson').select('*').eq('entity_id', entity.id).order('valid_from', { nullsFirst: true }),
		sb.from('media_items').select('*').eq('entity_id', entity.id).maybeSingle(),
		sb.from('event_details').select('*, event_types(label, color)').eq('entity_id', entity.id).maybeSingle(),
		sb.from('article_status_events').select('*').eq('entity_id', entity.id).order('created_at', { ascending: false }).limit(10),
		sb.rpc('tags_at', { p_entity: entity.id, p_at: null }),
		['building', 'site'].includes(entity.kind)
			? sb.rpc('building_spaces', { p_building: entity.id, p_at: yearToDate(year) })
			: Promise.resolve({ data: [] }),
		// for people who can clean up timelines: how many fixes this page has waiting
		canClean ? waitingFixes(sb, entity.id) : Promise.resolve(0)
	]);
	for (const r of [snapshot, timeline, relations, geoms]) if (r.error) error(500, r.error.message);

	const rels = (relations.data ?? []) as RelationRow[];
	const spaces = spacesRes.data;
	const tl = (timeline.data ?? []) as TimelineRow[];
	const body = article.data?.body ?? '';

	// Then what depends on it: the gallery (media that depicts this page), and the footnotes
	// (every source cited by a fact or the article) with the article rendered against them
	const mediaIds = rels.filter((r) => r.other_kind === 'media' && r.predicate === 'depicts').map((r) => r.other_id);
	const sourceIds = [
		...new Set([...tl.map((r) => r.source_id), ...rels.map((r) => r.source_id), mediaItem.data?.source_id, ...extractCitations(body)].filter(Boolean))
	] as string[];
	const [{ data: gallery }, { sources, html }] = await Promise.all([
		mediaIds.length
			? sb.from('entities').select('id, slug, name, exists_from, exists_from_precision, media_items(*)').in('id', mediaIds).order('exists_from', { nullsFirst: false })
			: Promise.resolve({ data: [] }),
		(async () => {
			const { data: sources } = sourceIds.length ? await sb.from('sources').select('*').in('id', sourceIds).order('title') : { data: [] };
			const footnote = Object.fromEntries((sources ?? []).map((s, i) => [s.id as string, i + 1]));
			return { sources, html: body ? await renderArticle(sb, body, footnote) : '' };
		})()
	]);

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
		html,
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
