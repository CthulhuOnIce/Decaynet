import { redirect } from '@sveltejs/kit';
import { ensureBootstrapped, siteHasAdmin } from '$lib/server/bootstrap';
import { loadSettings, loadVocabulary } from '$lib/server/db';
import { schemaStatus, type SchemaStatus } from '$lib/server/schema';
import type { Permission, Profile } from '$lib/types';
import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async ({ locals, url }) => {
	// Until a first admin exists, every page leads to the setup wizard
	if (!url.pathname.startsWith('/setup') && !url.pathname.startsWith('/auth/')) {
		if (!(await siteHasAdmin(locals.supabase))) {
			await ensureBootstrapped();
			if (!(await siteHasAdmin(locals.supabase))) redirect(303, '/setup');
		}
	}
	const { user } = await locals.safeGetSession();
	let profile: (Profile & { suspended: boolean }) | null = null;
	let perms: Permission[] = [];
	let openTips = 0;
	if (user) {
		const [p, pm] = await Promise.all([
			locals.supabase.from('profiles').select('*').eq('id', user.id).maybeSingle(),
			locals.supabase.rpc('my_permissions')
		]);
		profile = p.data;
		perms = (pm.data ?? []) as Permission[];
		if (perms.includes('review_tips')) {
			const { count } = await locals.supabase
				.from('tips')
				.select('id', { count: 'exact', head: true })
				.in('status', ['new', 'reviewing']);
			openTips = count ?? 0;
		}
	}
	const [vocab, settings] = await Promise.all([loadVocabulary(locals.supabase), loadSettings(locals.supabase)]);
	// Admins hear about a database that is behind this version of the app (the migrate step wasn't run)
	let schema: SchemaStatus | null = null;
	if (perms.includes('manage_settings')) {
		const s = await schemaStatus(locals.supabase);
		if (!s.ok) schema = s;
	}
	return { user, profile, perms, openTips, vocab, settings, schema };
};
