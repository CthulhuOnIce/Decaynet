import type { SiteSettings } from '$lib/types';
import { getSecret } from './admin';

const VERIFY: Record<string, string> = {
	turnstile: 'https://challenges.cloudflare.com/turnstile/v0/siteverify',
	hcaptcha: 'https://api.hcaptcha.com/siteverify'
};
export const CAPTCHA_FIELD: Record<string, string> = {
	turnstile: 'cf-turnstile-response',
	hcaptcha: 'h-captcha-response'
};

/** Verify a captcha token server-side. Returns null when OK, or a reason. */
export async function verifyCaptcha(settings: SiteSettings, fd: FormData, ip: string | null): Promise<string | null> {
	const provider = settings.tips_captcha_provider;
	if (provider === 'none') return null;
	const secret = await getSecret('tips_captcha_secret');
	if (!secret) return 'Captcha is enabled but no secret key is configured. Please tell the site admins.';
	const token = fd.get(CAPTCHA_FIELD[provider]);
	if (typeof token !== 'string' || !token) return 'Please complete the captcha.';
	const body = new URLSearchParams({ secret, response: token });
	if (ip) body.set('remoteip', ip);
	try {
		const res = await fetch(VERIFY[provider], { method: 'POST', body });
		const json = (await res.json()) as { success?: boolean };
		return json.success ? null : 'Captcha check failed. Please try again.';
	} catch {
		return 'Could not reach the captcha service. Please try again in a minute.';
	}
}

export async function hashIp(ip: string): Promise<string> {
	const salt = (await getSecret('ip_hash_salt')) ?? '';
	const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${salt}:${ip}`));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export const safeName = (name: string) =>
	name.toLowerCase().replace(/[^a-z0-9.]+/g, '-').replace(/^-+|-+$/g, '').slice(-60) || 'file';
