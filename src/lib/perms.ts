import { page } from '$app/state';
import { ADMIN_PERMS, type Permission } from './types';

/** Client-side permission check for showing/hiding UI. The database enforces the real rule. */
export const can = (p: Permission): boolean => ((page.data.perms ?? []) as Permission[]).includes(p);
export const canAdmin = (): boolean => ADMIN_PERMS.some(can);
