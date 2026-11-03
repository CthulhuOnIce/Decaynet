import type { SupabaseClient } from '@supabase/supabase-js';
import { serviceClient } from './admin';

/**
 * Archived copies of source links (migration 0029).
 *
 * New and changed sources are queued here and saved to the Internet Archive in
 * the background: a recent existing snapshot is reused, otherwise "Save Page
 * Now" is asked for one. A sweep picks up older sources and retries failures
 * once a day. Needs SUPABASE_SERVICE_ROLE_KEY for the sweep; without it, new
 * sources are still archived right after they're saved, as the editor.
 */

const AVAILABLE = 'https://archive.org/wayback/available';
const WAYBACK = 'https://web.archive.org';
/** An existing snapshot older than this gets a fresh save (falling back to it if saving fails). */
const FRESH_DAYS = 365;
/** Anonymous Save Page Now allows a handful of saves a minute; stay well under. */
const SAVE_SPACING_MS = 20_000;
const SWEEP_EVERY_MS = 15 * 60_000;
const SWEEP_BATCH = 10;

export interface WaybackOptions {
	fetch?: typeof fetch;
	available?: string;
	wayback?: string;
	spacingMs?: number;
	now?: () => Date;
}

const https = (u: string) => u.replace(/^http:\/\//i, 'https://');

/** File-sharing hosts whose links are often "anyone with the link": archiving one would make it public. */
const SHARE_HOSTS = /(^|\.)(drive\.google\.com|docs\.google\.com|photos\.google\.com|dropbox\.com|dropboxusercontent\.com|onedrive\.live\.com|1drv\.ms|sharepoint\.com|box\.com|icloud\.com|mega\.nz|wetransfer\.com|we\.tl)$/;
/** Query parameters that carry a credential or signed access. */
const SECRET_PARAMS = /^(token|access_token|auth|key|api_key|apikey|sig|signature|x-amz-signature|x-goog-signature|se|sv|password|pwd|code|secret|session)$/i;

/** Why a link isn't sent to the archive, or null if it can be. */
export function notArchivable(raw: string | null | undefined): string | null {
	if (!raw) return 'No link.';
	let u: URL;
	try {
		u = new URL(raw);
	} catch {
		return "The link isn't a valid web address.";
	}
	if (u.protocol !== 'http:' && u.protocol !== 'https:') return 'Only web (http/https) links are archived.';
	const h = u.hostname.toLowerCase();
	if (h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || !h.includes('.')) return 'Not archived: a private address.';
	if (/^(127|10)\./.test(h) || /^192\.168\./.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h) || h.includes(':')) return 'Not archived: a private address.';
	if (SHARE_HOSTS.test(h) || u.username || u.password || [...u.searchParams.keys()].some((k) => SECRET_PARAMS.test(k)))
		return 'Not archived: it looks like a private share link, which archiving would make public. Add an archived copy by hand if it is public.';
	if ((u.pathname === '/' || u.pathname === '') && !u.search) return "Not archived: only specific pages are saved, not a site's home page.";
	return null;
}

/** Worth archiving: a public http(s) page, not a site's bare home page, a private address or a share link. */
export function archivable(raw: string | null | undefined): boolean {
	return notArchivable(raw) === null;
}

let lastSave = 0;

/** The archived copy of a link: a recent snapshot if there is one, otherwise a new one. */
export async function findOrCreateSnapshot(url: string, userAgent: string, opt: WaybackOptions = {}): Promise<string> {
	const f = opt.fetch ?? fetch;
	const available = opt.available ?? AVAILABLE;
	const wayback = opt.wayback ?? WAYBACK;
	const now = (opt.now ?? (() => new Date()))();
	const stamp = now.toISOString().replace(/\D/g, '').slice(0, 14);
	const headers = { 'user-agent': userAgent, accept: 'application/json' };

	const lookup = async (): Promise<{ url: string; at: Date } | null> => {
		const r = await f(`${available}?url=${encodeURIComponent(url)}&timestamp=${stamp}`, { headers, signal: AbortSignal.timeout(20_000) });
		if (!r.ok) return null;
		const c = ((await r.json()) as { archived_snapshots?: { closest?: { available?: boolean; status?: string; url?: string; timestamp?: string } } })
			?.archived_snapshots?.closest;
		if (!c?.available || !c.url || !String(c.status ?? '').startsWith('2')) return null;
		const t = c.timestamp ?? '';
		const at = new Date(Date.UTC(+t.slice(0, 4), +t.slice(4, 6) - 1, +t.slice(6, 8)));
		return { url: https(c.url), at };
	};

	const existing = await lookup();
	if (existing && now.getTime() - existing.at.getTime() < FRESH_DAYS * 86_400_000) return existing.url;

	// Ask for a fresh snapshot, politely spaced
	const spacing = opt.spacingMs ?? SAVE_SPACING_MS;
	const wait = lastSave + spacing - Date.now();
	if (wait > 0) await new Promise((r) => setTimeout(r, wait));
	lastSave = Date.now();
	try {
		const s = await f(`${wayback}/save/${url}`, { headers: { 'user-agent': userAgent }, redirect: 'manual', signal: AbortSignal.timeout(120_000) });
		const loc = s.headers.get('location') ?? s.headers.get('content-location');
		if (loc && /\/web\/\d{14}/.test(loc)) return https(new URL(loc, wayback).toString());
		if (s.status === 429) throw new Error('The Internet Archive is limiting saves right now; it will be retried.');
		if (s.status >= 400) throw new Error(`The Internet Archive couldn't save it (HTTP ${s.status}).`);
		const again = await lookup();
		if (again) return again.url;
		throw new Error('The Internet Archive accepted the page but has no snapshot yet; it will be retried.');
	} catch (e) {
		if (existing) return existing.url; // an older copy beats none
		throw e;
	}
}

/** Archive one source's link, if it has one and no archived copy yet. */
export async function archiveSource(sb: SupabaseClient, id: string, opt: WaybackOptions = {}): Promise<'archived' | 'skipped' | 'failed'> {
	const [{ data: s }, { data: st }] = await Promise.all([
		sb.from('sources').select('id, url, archive_url').eq('id', id).maybeSingle(),
		sb.from('site_settings').select('archive_sources, site_name, source_code_url').single()
	]);
	if (!s?.url || s.archive_url || !st?.archive_sources) return 'skipped';
	const mark = (fields: Record<string, unknown>) =>
		sb.from('sources').update({ archive_checked_at: new Date().toISOString(), ...fields }).eq('id', id).is('archive_url', null);
	// Page sources (cited by one page's facts or article) and library sources alike; the link is
	// someone else's page, and the archive doesn't record which page cited it.
	const why = notArchivable(s.url);
	if (why) {
		await mark({ archive_error: why });
		return 'skipped';
	}
	const ua = `${String(st.site_name).replace(/[^\w .-]/g, '')}/1.0 (Decaynet; ${st.source_code_url})`;
	try {
		const snapshot = await findOrCreateSnapshot(s.url, ua, opt);
		await mark({ archive_url: snapshot, archive_auto: true, archive_error: null });
		return 'archived';
	} catch (e) {
		await mark({ archive_error: (e as Error).message.slice(0, 300) });
		return 'failed';
	}
}

// ----------------------------------------------------------------------------- background queue

const queue: { id: string; sb: SupabaseClient }[] = [];
const queued = new Set<string>();
let running = false;

/** Archive a source soon, without holding up the request (service key if set, else the editor's client). */
export function queueArchive(id: string, sb?: SupabaseClient) {
	const client = serviceClient() ?? sb;
	if (!client || queued.has(id)) return;
	queued.add(id);
	queue.push({ id, sb: client });
	void drain();
}

async function drain() {
	if (running) return;
	running = true;
	try {
		while (queue.length) {
			const job = queue.shift()!;
			queued.delete(job.id);
			try {
				await archiveSource(job.sb, job.id);
			} catch (e) {
				console.warn(`[decaynet] archiving source ${job.id} failed: ${(e as Error).message}`);
			}
		}
	} finally {
		running = false;
	}
}

let sweeping: ReturnType<typeof setInterval> | null = null;

/** Every 15 minutes: queue sources still without an archived copy (new, or last tried over a day ago). */
export function startArchiveSweep() {
	const sb = serviceClient();
	if (!sb || sweeping) return;
	const sweep = async () => {
		const { data: st } = await sb.from('site_settings').select('archive_sources').single();
		if (!st?.archive_sources) return; // turned off (or the database predates migration 0029)
		const dayAgo = new Date(Date.now() - 86_400_000).toISOString();
		const { data, error } = await sb
			.from('sources')
			.select('id')
			.not('url', 'is', null)
			.is('archive_url', null)
			.or(`archive_checked_at.is.null,archive_checked_at.lt.${dayAgo}`)
			.order('archive_checked_at', { ascending: true, nullsFirst: true })
			.limit(SWEEP_BATCH);
		if (error) return;
		for (const r of data ?? []) queueArchive(r.id);
	};
	sweeping = setInterval(() => void sweep().catch(() => {}), SWEEP_EVERY_MS);
	(sweeping as { unref?: () => void }).unref?.();
	setTimeout(() => void sweep().catch(() => {}), 30_000);
}
