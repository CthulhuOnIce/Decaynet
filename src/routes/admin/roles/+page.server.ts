import { fail } from '@sveltejs/kit';
import { requirePermission } from '$lib/server/db';
import { dbMessage, str } from '$lib/server/forms';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	await requirePermission(locals, 'manage_settings');
	const [roles, permissions, grants, profiles] = await Promise.all([
		locals.supabase.from('roles').select('*').order('rank'),
		locals.supabase.from('permissions').select('*').order('sort'),
		locals.supabase.from('role_permissions').select('*'),
		locals.supabase.from('profiles').select('role')
	]);
	const counts: Record<string, number> = {};
	for (const p of profiles.data ?? []) counts[p.role] = (counts[p.role] ?? 0) + 1;
	return {
		roles: roles.data ?? [],
		permissions: permissions.data ?? [],
		grants: new Set((grants.data ?? []).map((g) => `${g.role}:${g.permission}`)) as Set<string>,
		counts
	};
};

export const actions: Actions = {
	toggle: async ({ request, locals }) => {
		await requirePermission(locals, 'manage_settings');
		const fd = await request.formData();
		const role = str(fd, 'role')!;
		const permission = str(fd, 'permission')!;
		const res =
			fd.get('on') === 'true'
				? await locals.supabase.from('role_permissions').insert({ role, permission })
				: await locals.supabase.from('role_permissions').delete().match({ role, permission });
		if (res.error) return fail(400, { error: dbMessage(res.error) });
	},
	addRole: async ({ request, locals }) => {
		await requirePermission(locals, 'manage_settings');
		const fd = await request.formData();
		const label = str(fd, 'label');
		if (!label) return fail(400, { error: 'Name the role.' });
		const id = label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
		const { error } = await locals.supabase
			.from('roles')
			.insert({ id, label, description: str(fd, 'description'), rank: Number(str(fd, 'rank') ?? 15) });
		if (error) return fail(400, { error: dbMessage(error) });
		return { ok: `Role “${label}” created.` };
	},
	deleteRole: async ({ request, locals }) => {
		await requirePermission(locals, 'manage_settings');
		const fd = await request.formData();
		const { error } = await locals.supabase.from('roles').delete().eq('id', str(fd, 'role')).eq('builtin', false);
		if (error) return fail(400, { error: error.code === '23503' ? 'Move its users to another role first.' : dbMessage(error) });
	}
};
