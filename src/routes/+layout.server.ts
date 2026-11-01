import { loadVocabulary } from '$lib/server/db';
import type { Profile } from '$lib/types';
import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async ({ locals }) => {
	const { user } = await locals.safeGetSession();
	let profile: Profile | null = null;
	if (user) {
		const { data } = await locals.supabase.from('profiles').select('*').eq('id', user.id).maybeSingle();
		profile = data;
	}
	return {
		user,
		profile,
		vocab: await loadVocabulary(locals.supabase)
	};
};
