import { fail } from '@sveltejs/kit';
import { serviceClient } from '$lib/server/admin';
import { str } from '$lib/server/forms';
import { hashIp, safeName, verifyCaptcha } from '$lib/server/tips';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ parent, url, locals }) => {
	const { settings } = await parent();
	const slug = url.searchParams.get('about');
	const { data: about } = slug
		? await locals.supabase.from('entities').select('id, name').eq('slug', slug).maybeSingle()
		: { data: null };
	return { open: settings.tips_enabled && !!serviceClient(), about };
};

export const actions: Actions = {
	default: async (event) => {
		const { request, locals, getClientAddress } = event;
		const admin = serviceClient();
		const { data: settings } = await locals.supabase.from('site_settings').select('*').single();
		if (!admin || !settings?.tips_enabled) return fail(503, { error: 'Tips are not being accepted right now.' });

		const fd = await request.formData();
		// Honeypot: real people never fill this hidden field
		if (str(fd, 'website_url')) return { ok: true };

		let ip: string | null = null;
		try {
			ip = getClientAddress();
		} catch {
			ip = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? null;
		}

		const captchaError = await verifyCaptcha(settings, fd, ip);
		if (captchaError) return fail(400, { error: captchaError });

		const body = str(fd, 'body');
		if (!body || body.length < 10) return fail(400, { error: 'Tell us a bit more (at least a sentence).' });
		if (body.length > 20000) return fail(400, { error: 'That is too long; please split it into a few tips.' });

		// IP handling per settings, and the rate limit
		const ipHash = ip && settings.tips_ip_mode !== 'off' ? await hashIp(ip) : null;
		if (ipHash && settings.tips_rate_limit_per_hour > 0) {
			const since = new Date(Date.now() - 3600_000).toISOString();
			const { count } = await admin
				.from('tips')
				.select('id', { count: 'exact', head: true })
				.eq('ip_hash', ipHash)
				.gte('created_at', since);
			if ((count ?? 0) >= settings.tips_rate_limit_per_hour)
				return fail(429, { error: 'You have sent several tips recently. Please try again in an hour.' });
		}

		// Optional point
		let location: string | null = null;
		const geo = str(fd, 'geojson');
		if (geo) {
			try {
				const g = JSON.parse(geo);
				if (g?.type === 'Point' && g.coordinates?.length === 2 && g.coordinates.every(Number.isFinite))
					location = `SRID=4326;POINT(${g.coordinates[0]} ${g.coordinates[1]})`;
			} catch {
				/* ignore a bad location */
			}
		}

		// Images, uploaded to the private bucket
		const tipId = crypto.randomUUID();
		const images: { path: string; name: string; mime: string; size: number }[] = [];
		const files = fd.getAll('images').filter((f): f is File => f instanceof File && f.size > 0);
		if (files.length) {
			if (!settings.tips_allow_images) return fail(400, { error: 'This site does not accept images with tips.' });
			if (files.length > settings.tips_max_images)
				return fail(400, { error: `At most ${settings.tips_max_images} images per tip.` });
			for (const [i, f] of files.entries()) {
				if (!f.type.startsWith('image/')) return fail(400, { error: `${f.name} is not an image.` });
				if (f.size > settings.tips_max_image_mb * 1024 * 1024)
					return fail(400, { error: `${f.name} is larger than ${settings.tips_max_image_mb} MB.` });
				const path = `${tipId}/${i + 1}-${safeName(f.name)}`;
				const up = await admin.storage.from('tips').upload(path, f, { contentType: f.type });
				if (up.error) return fail(500, { error: `Upload failed: ${up.error.message}` });
				images.push({ path, name: f.name, mime: f.type, size: f.size });
			}
		}

		const aboutId = str(fd, 'about_entity_id');
		const { error } = await admin.from('tips').insert({
			id: tipId,
			subject: str(fd, 'subject'),
			body,
			about_entity_id: aboutId && /^[0-9a-f-]{36}$/i.test(aboutId) ? aboutId : null,
			about_text: str(fd, 'about_text'),
			when_text: str(fd, 'when_text'),
			contact: str(fd, 'contact'),
			location,
			images,
			ip_address: settings.tips_ip_mode === 'full' ? ip : null,
			ip_hash: ipHash,
			user_agent: request.headers.get('user-agent')?.slice(0, 300) ?? null,
			captcha_verified: settings.tips_captcha_provider !== 'none'
		});
		if (error) {
			if (images.length) await admin.storage.from('tips').remove(images.map((i) => i.path));
			return fail(500, { error: 'Could not save your tip. Please try again.' });
		}
		return { ok: true };
	}
};
