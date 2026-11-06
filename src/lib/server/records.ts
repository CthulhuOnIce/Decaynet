/** Admin › Records: the change set this admin has open (a cookie on /admin/records). */
export const SET_COOKIE = 'dn_records_set';
export const SET_COOKIE_OPTS = { path: '/admin/records', httpOnly: true, sameSite: 'lax' as const, maxAge: 60 * 60 * 24 * 60 };
