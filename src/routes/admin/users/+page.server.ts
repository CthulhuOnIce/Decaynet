import { fail } from '@sveltejs/kit';
import { requirePermission } from '$lib/server/db';
import { serviceClient } from '$lib/server/admin';
import { dbMessage, str } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, url }) => {
	await requirePermission(locals, 'manage_users');
	const q = url.searchParams.get('q')?.trim() ?? '';
	const role = url.searchParams.get('role') ?? '';
	let query = locals.supabase.from('profiles').select('*').order('created_at', { ascending: false }).limit(500);
	if (q) query = query.ilike('display_name', `%${q}%`);
	if (role) query = query.eq('role', role);
	const [{ data: users }, { data: roles }] = await Promise.all([
		query,
		locals.supabase.from('roles').select('*').order('rank')
	]);

	// Emails live in auth.users; only visible with the service key configured
	const emails: Record<string, string> = {};
	const admin = serviceClient();
	if (admin) {
		const { data } = await admin.auth.admin.listUsers({ perPage: 1000 });
		for (const u of data?.users ?? []) if (u.email) emails[u.id] = u.email;
	}
	return { users: users ?? [], roles: roles ?? [], emails, hasServiceKey: !!admin, q, role };
};

export const actions: Actions = {
	setRole: async ({ request, locals }) => {
		await requirePermission(locals, 'manage_users');
		const fd = await request.formData();
		const { error } = await locals.supabase.from('profiles').update({ role: str(fd, 'role') }).eq('id', str(fd, 'id'));
		if (error) return fail(400, { error: dbMessage(error) });
		return { ok: 'Role updated.' };
	},
	suspend: async ({ request, locals }) => {
		await requirePermission(locals, 'manage_users');
		const fd = await request.formData();
		const suspended = fd.get('suspended') === 'true';
		const { error } = await locals.supabase
			.from('profiles')
			.update({ suspended, suspended_reason: suspended ? str(fd, 'reason') : null })
			.eq('id', str(fd, 'id'));
		if (error) return fail(400, { error: dbMessage(error) });
		return { ok: suspended ? 'User suspended.' : 'Suspension lifted.' };
	}
};
