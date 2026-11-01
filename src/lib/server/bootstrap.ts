import type { SupabaseClient } from '@supabase/supabase-js';
import { env as priv } from '$env/dynamic/private';
import { serviceClient } from './admin';

/**
 * First-admin bootstrap.
 *
 *  1. ADMIN_EMAIL + ADMIN_PASSWORD set → that account is created (or an existing
 *     one promoted) as admin when the server starts, if the site has no admin.
 *  2. Otherwise the site redirects to /setup, a one-time wizard protected by a
 *     setup code: SETUP_TOKEN if set, else a random code printed to the logs.
 *  3. Without SUPABASE_SERVICE_ROLE_KEY (plain dev setups), the first account
 *     to sign up becomes admin, and /setup is a simple sign-up form.
 */

let adminKnown = false;
let setupCode: string | null = null;
let attempt: Promise<void> | null = null;

const randomCode = () => {
	const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
	const bytes = crypto.getRandomValues(new Uint8Array(12));
	const s = [...bytes].map((b) => alphabet[b % alphabet.length]).join('');
	return `${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}`;
};

export const markAdminKnown = () => void (adminKnown = true);
export const getSetupCode = () => setupCode;
export const usesSetupCode = () => !!serviceClient();

/** Is there an admin yet? Cached once true (it never goes back). */
export async function siteHasAdmin(sb: SupabaseClient): Promise<boolean> {
	if (adminKnown) return true;
	const { data } = await sb.rpc('site_has_admin');
	if (data) adminKnown = true;
	return !!data;
}

/** Create (or find) an auth user and make it the site's admin. Service role only. */
export async function createAdmin(email: string, password: string, name: string): Promise<string> {
	const admin = serviceClient();
	if (!admin) throw new Error('SUPABASE_SERVICE_ROLE_KEY is not configured.');
	let userId: string;
	const { data, error } = await admin.auth.admin.createUser({
		email,
		password,
		email_confirm: true,
		user_metadata: { display_name: name }
	});
	if (error) {
		// Already registered? Promote that account instead (its password is left unchanged).
		const { data: list } = await admin.auth.admin.listUsers({ perPage: 1000 });
		const existing = list?.users.find((u) => u.email?.toLowerCase() === email.toLowerCase());
		if (!existing) throw new Error(error.message);
		userId = existing.id;
	} else userId = data.user.id;
	const { error: claimError } = await admin.rpc('claim_admin', { p_user: userId });
	if (claimError) throw new Error(claimError.message);
	adminKnown = true;
	return userId;
}

async function run() {
	const admin = serviceClient();
	if (!admin) {
		console.warn('[decaynet] SUPABASE_SERVICE_ROLE_KEY not set: the first account to sign up becomes admin.');
		return;
	}
	const { data: has, error } = await admin.rpc('site_has_admin');
	if (error) throw new Error(`database not ready (${error.message})`);
	if (has) {
		adminKnown = true;
		return;
	}
	// From now on nobody becomes admin just by signing up first
	await admin.from('site_settings').update({ admin_bootstrap: 'closed' }).eq('id', true);

	const email = priv.ADMIN_EMAIL?.trim();
	const password = priv.ADMIN_PASSWORD;
	if (email && password) {
		await createAdmin(email, password, priv.ADMIN_NAME?.trim() || email.split('@')[0]);
		console.log(`[decaynet] Admin account ${email} created from ADMIN_EMAIL / ADMIN_PASSWORD.`);
		return;
	}
	if (email || password) console.warn('[decaynet] Set both ADMIN_EMAIL and ADMIN_PASSWORD to create the admin automatically.');

	setupCode = priv.SETUP_TOKEN?.trim() || randomCode();
	const origin = (priv.ORIGIN ?? '').replace(/\/$/, '');
	const where = origin ? `${origin}/setup` : '/setup on this site';
	const line = '='.repeat(64);
	console.log(
		`\n${line}\n  Decaynet setup: no admin account yet.\n  Open ${where} and enter the setup code:\n\n      ${setupCode}\n\n  (or set ADMIN_EMAIL + ADMIN_PASSWORD, or SETUP_TOKEN, and restart)\n${line}\n`
	);
}

/** Run once at startup; retried on later requests if the database wasn't ready. */
export function ensureBootstrapped(): Promise<void> {
	attempt ??= run().catch((e) => {
		console.warn(`[decaynet] admin bootstrap will retry: ${(e as Error).message}`);
		attempt = null;
	});
	return attempt;
}

/** Constant-time comparison for the setup code. */
export function checkSetupCode(given: string): boolean {
	const want = setupCode;
	if (!want) return false;
	const a = given.trim().toUpperCase();
	const b = want.toUpperCase();
	let diff = a.length ^ b.length;
	for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
	return diff === 0;
}
