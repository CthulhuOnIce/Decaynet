import { loadSettings, loadVocabulary } from '$lib/server/db';
import type { Permission, Profile } from '$lib/types';
import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async ({ locals }) => {
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
	return { user, profile, perms, openTips, vocab, settings };
};
