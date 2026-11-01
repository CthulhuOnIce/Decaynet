import { fail } from '@sveltejs/kit';
import { requirePermission } from '$lib/server/db';
import { serviceClient } from '$lib/server/admin';
import { dbMessage, str } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	await requirePermission(locals, 'manage_settings');
	const [{ data: secrets }, { data: roles }] = await Promise.all([
		locals.supabase.rpc('site_secret_status'),
		locals.supabase.from('roles').select('id, label').order('rank')
	]);
	return {
		secrets: Object.fromEntries((secrets ?? []).map((s: { key: string; is_set: boolean }) => [s.key, s.is_set])) as Record<string, boolean>,
		roles: roles ?? [],
		hasServiceKey: !!serviceClient()
	};
};

const num = (fd: FormData, k: string) => {
	const v = Number(str(fd, k));
	if (!Number.isFinite(v)) throw new Error(`${k} must be a number`);
	return v;
};
const bool = (fd: FormData, k: string) => fd.get(k) === 'on';

export const actions: Actions = {
	save: async ({ request, locals }) => {
		await requirePermission(locals, 'manage_settings');
		const fd = await request.formData();
		try {
			const basemap = str(fd, 'basemap_url') ?? '';
			if (!/^https:\/\/.+\{z\}.+\{x\}.+\{y\}/.test(basemap)) throw new Error('Basemap URL must be https with {z}, {x}, {y}.');
			const update = {
				site_name: str(fd, 'site_name') ?? 'Decaynet',
				tagline: str(fd, 'tagline') ?? '',
				region_name: str(fd, 'region_name') ?? '',
				about: String(fd.get('about') ?? ''),
				map_center_lon: num(fd, 'map_center_lon'),
				map_center_lat: num(fd, 'map_center_lat'),
				map_zoom: num(fd, 'map_zoom'),
				default_year: num(fd, 'default_year'),
				min_year: num(fd, 'min_year'),
				basemap_url: basemap,
				basemap_attribution: str(fd, 'basemap_attribution') ?? '',
				basemap_mode: str(fd, 'basemap_mode') ?? 'fade',
				allow_signups: bool(fd, 'allow_signups'),
				default_role: str(fd, 'default_role') ?? 'contributor',
				tips_enabled: bool(fd, 'tips_enabled'),
				tips_intro: str(fd, 'tips_intro') ?? '',
				tips_allow_images: bool(fd, 'tips_allow_images'),
				tips_max_images: num(fd, 'tips_max_images'),
				tips_max_image_mb: num(fd, 'tips_max_image_mb'),
				tips_ip_mode: str(fd, 'tips_ip_mode') ?? 'hash',
				tips_captcha_provider: str(fd, 'tips_captcha_provider') ?? 'none',
				tips_captcha_site_key: str(fd, 'tips_captcha_site_key'),
				tips_rate_limit_per_hour: num(fd, 'tips_rate_limit_per_hour')
			};
			if (update.tips_captcha_provider !== 'none' && !update.tips_captcha_site_key)
				throw new Error('A captcha provider needs a site key (and a secret below).');
			const { error } = await locals.supabase.from('site_settings').update(update).eq('id', true);
			if (error) throw new Error(dbMessage(error));
			return { section: 'settings', ok: 'Settings saved.' };
		} catch (e) {
			return fail(400, { section: 'settings', error: (e as Error).message });
		}
	},
	secret: async ({ request, locals }) => {
		await requirePermission(locals, 'manage_settings');
		const fd = await request.formData();
		const { error } = await locals.supabase.rpc('set_site_secret', {
			p_key: str(fd, 'key'),
			p_value: fd.get('clear') ? '' : (str(fd, 'value') ?? '')
		});
		if (error) return fail(400, { section: 'secret', error: dbMessage(error) });
		return { section: 'secret', ok: 'Secret updated.' };
	}
};
