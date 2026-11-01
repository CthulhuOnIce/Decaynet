import { error } from '@sveltejs/kit';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { Entity, Permission, SiteSettings, TagRow, Vocabulary } from '$lib/types';

export async function entityBySlug(supabase: SupabaseClient, slug: string): Promise<Entity> {
	const { data, error: err } = await supabase.from('entities').select('*').eq('slug', slug).maybeSingle();
	if (err) error(500, err.message);
	if (!data) error(404, `No page called “${slug}” yet.`);
	return data as Entity;
}

export async function loadVocabulary(supabase: SupabaseClient): Promise<Vocabulary> {
	const [kinds, statuses, relationTypes, eventTypes, attributeKeys, articleStatuses, tagFacets] = await Promise.all([
		supabase.from('entity_kinds').select('*').order('sort'),
		supabase.from('lifecycle_statuses').select('*').order('sort'),
		supabase.from('relation_types').select('*').order('sort'),
		supabase.from('event_types').select('*').order('sort'),
		supabase.from('attribute_keys').select('*').order('sort'),
		supabase.from('article_statuses').select('*').order('sort'),
		supabase.from('tag_facets').select('*').order('sort')
	]);
	const failed = [kinds, statuses, relationTypes, eventTypes, attributeKeys, articleStatuses, tagFacets].find((r) => r.error);
	if (failed?.error) error(500, `Could not load vocabulary: ${failed.error.message}`);
	return {
		kinds: kinds.data ?? [],
		statuses: statuses.data ?? [],
		relationTypes: relationTypes.data ?? [],
		eventTypes: eventTypes.data ?? [],
		attributeKeys: attributeKeys.data ?? [],
		articleStatuses: articleStatuses.data ?? [],
		tagFacets: tagFacets.data ?? []
	};
}

/** Every tag with its full path ("Food & drink › Restaurant › Soul food"), ordered as a tree. */
export async function loadTags(supabase: SupabaseClient): Promise<TagRow[]> {
	const { data, error: err } = await supabase.from('tag_index').select('*').order('facet').order('path');
	if (err) error(500, err.message);
	return (data ?? []) as TagRow[];
}

export async function requireEditor(locals: App.Locals) {
	const { user } = await locals.safeGetSession();
	if (!user) error(401, 'Sign in to contribute.');
	return user;
}

/** Server-side gate; RLS enforces the same rule in the database. */
export async function requirePermission(locals: App.Locals, permission: Permission) {
	const user = await requireEditor(locals);
	const { data } = await locals.supabase.rpc('has_permission', { p_permission: permission });
	if (!data) error(403, `You don't have the “${permission.replace('_', ' ')}” permission.`);
	return user;
}

export async function loadSettings(supabase: SupabaseClient): Promise<SiteSettings> {
	const { data, error: err } = await supabase.from('site_settings').select('*').single();
	if (err) error(500, `Could not load site settings: ${err.message}`);
	return data as SiteSettings;
}

/** Public URL for an object in the media bucket. */
export function mediaUrl(supabase: SupabaseClient, path: string | null, external: string | null) {
	if (path) return supabase.storage.from('media').getPublicUrl(path).data.publicUrl;
	return external;
}
