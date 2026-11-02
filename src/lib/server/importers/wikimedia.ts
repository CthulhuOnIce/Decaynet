import type { Candidate, ImportOptions } from '$lib/importTypes';
import { parseOsmDate } from './dates';
import { kindFor, tagSlugs } from './wikidata';

type Box = ImportOptions['bbox'];

const MAX_TILE = 0.07; // the geosearch API refuses boxes much beyond 10 km

function tiles([w, s, e, n]: Box): Box[] {
	const out: Box[] = [];
	const nx = Math.max(1, Math.ceil((e - w) / MAX_TILE));
	const ny = Math.max(1, Math.ceil((n - s) / MAX_TILE));
	for (let i = 0; i < nx; i++)
		for (let j = 0; j < ny; j++)
			out.push([w + ((e - w) * i) / nx, s + ((n - s) * j) / ny, w + ((e - w) * (i + 1)) / nx, s + ((n - s) * (j + 1)) / ny]);
	return out;
}

async function api<T>(host: string, params: Record<string, string>, userAgent: string): Promise<T> {
	const url = `https://${host}/w/api.php?${new URLSearchParams({ format: 'json', formatversion: '2', ...params })}`;
	const res = await fetch(url, { headers: { 'user-agent': userAgent, accept: 'application/json' }, signal: AbortSignal.timeout(30_000) });
	if (!res.ok) throw new Error(`${host} returned ${res.status}`);
	const json = (await res.json()) as T & { error?: { info: string } };
	if (json.error) throw new Error(`${host}: ${json.error.info}`);
	return json;
}

interface GeoHit {
	pageid: number;
	title: string;
	lat: number;
	lon: number;
}

const CAP = 300;
const LIMIT_HIT = 'geosearch hit its 500-result limit in part of this area; draw a smaller box to see everything';

/** Geotagged pages inside the box (all tiles, de-duplicated, capped). */
async function geosearch(host: string, bbox: Box, userAgent: string, extra: Record<string, string> = {}) {
	const seen = new Map<number, GeoHit>();
	let truncated = false;
	for (const [w, s, e, n] of tiles(bbox)) {
		const r = await api<{ query?: { geosearch: GeoHit[] } }>(
			host,
			{ action: 'query', list: 'geosearch', gsbbox: `${n}|${w}|${s}|${e}`, gslimit: '500', ...extra },
			userAgent
		);
		const hits = r.query?.geosearch ?? [];
		if (hits.length >= 500) truncated = true;
		for (const h of hits) seen.set(h.pageid, h);
	}
	return { hits: [...seen.values()].slice(0, CAP), truncated: truncated || seen.size > CAP };
}

const chunks = <T>(a: T[], n: number) => Array.from({ length: Math.ceil(a.length / n) }, (_, i) => a.slice(i * n, i * n + n));

const slug = (t: string) => encodeURIComponent(t.replace(/ /g, '_')).replace(/%2F/g, '/').replace(/%3A/g, ':');
const point = (lon: number, lat: number): GeoJSON.Point => ({ type: 'Point', coordinates: [+lon.toFixed(7), +lat.toFixed(7)] });

// ----------------------------------------------------------------------------- Wikipedia

export interface WikipediaPage extends GeoHit {
	extract?: string;
	qid?: string;
	shortdesc?: string;
}

export async function fetchWikipedia(bbox: Box, userAgent: string, lang: string) {
	const host = `${/^[a-z]{2,3}(-[a-z]{2,4})?$/i.test(lang) ? lang.toLowerCase() : 'en'}.wikipedia.org`;
	const { hits, truncated } = await geosearch(host, bbox, userAgent, { gsnamespace: '0', gsprop: '' });
	const byId = new Map(hits.map((h) => [h.pageid, h as WikipediaPage]));
	for (const group of chunks(hits.map((h) => h.pageid), 20)) {
		const r = await api<{ query?: { pages: { pageid: number; extract?: string; pageprops?: Record<string, string> }[] } }>(
			host,
			{
				action: 'query', pageids: group.join('|'), prop: 'extracts|pageprops', exintro: '1', explaintext: '1', exsentences: '3',
				exlimit: '20', ppprop: 'wikibase_item|wikibase-shortdesc'
			},
			userAgent
		);
		for (const p of r.query?.pages ?? []) {
			const page = byId.get(p.pageid);
			if (!page) continue;
			page.extract = p.extract?.replace(/\s+/g, ' ').trim();
			page.qid = p.pageprops?.wikibase_item;
			page.shortdesc = p.pageprops?.['wikibase-shortdesc'];
		}
	}
	return { pages: [...byId.values()], host, warning: truncated ? `Wikipedia ${LIMIT_HIT}.` : null };
}

/** Articles about people and abstract things make poor map pages. */
const NOT_PLACES = /\b(politician|actor|actress|footballer|baseball|basketball|player|musician|singer|rapper|novelist|writer|poet|painter|businessman|businesswoman|athlete|born|died|activist|mayor|judge|lawyer|album|song|film|television series)\b/i;

export function normalizeWikipedia(pages: WikipediaPage[], host: string): Candidate[] {
	const lang = host.split('.')[0];
	const out: Candidate[] = [];
	for (const p of pages) {
		const desc = p.shortdesc ?? '';
		if (NOT_PLACES.test(desc)) continue;
		const kind = kindFor(desc ? [desc] : []);
		if (!kind) continue;
		const summary = (p.extract && p.extract.length > 20 ? p.extract : desc || null)?.slice(0, 700) ?? null;
		const url = `https://${host}/wiki/${slug(p.title)}`;
		out.push({
			key: `wikipedia:${lang}:${p.pageid}`,
			origin: 'wikipedia',
			kind,
			name: p.title.replace(/\s+\([^)]*\)$/, ''),
			unnamed: false,
			summary,
			exists_from: null,
			exists_from_precision: 'year',
			exists_to: null,
			exists_to_precision: 'year',
			approximate: false,
			geometry: point(p.lon, p.lat),
			geometry_source: 'wikipedia',
			fact_source: 'wikipedia',
			role: 'point',
			names: [],
			attributes: [],
			tags: tagSlugs(desc ? [desc] : []),
			ext: [{ source: 'wikipedia', id: `${lang}:${p.title}`, url }],
			wikidata: p.qid && /^Q\d+$/.test(p.qid) ? p.qid : null,
			image_url: null,
			classes: desc ? [desc] : [],
			raw: { title: p.title, description: desc, qid: p.qid ?? '' }
		});
	}
	return out;
}

// ----------------------------------------------------------------------------- Commons

interface CommonsMeta {
	value?: string;
}
interface CommonsPage {
	pageid: number;
	title: string;
	imageinfo?: {
		url: string;
		thumburl?: string;
		descriptionurl: string;
		mime?: string;
		extmetadata?: Record<string, CommonsMeta>;
	}[];
}
export interface CommonsFile extends GeoHit {
	info?: NonNullable<CommonsPage['imageinfo']>[number];
}

export async function fetchCommons(bbox: Box, userAgent: string) {
	const host = 'commons.wikimedia.org';
	const { hits, truncated } = await geosearch(host, bbox, userAgent, { gsnamespace: '6', gsprop: '' });
	const byId = new Map(hits.map((h) => [h.pageid, h as CommonsFile]));
	for (const group of chunks(hits.map((h) => h.pageid), 50)) {
		const r = await api<{ query?: { pages: CommonsPage[] } }>(
			host,
			{
				action: 'query', pageids: group.join('|'), prop: 'imageinfo', iiprop: 'url|mime|extmetadata', iiurlwidth: '1280',
				iiextmetadatafilter: 'Artist|LicenseShortName|ImageDescription|DateTimeOriginal|Credit'
			},
			userAgent
		);
		for (const p of r.query?.pages ?? []) {
			const f = byId.get(p.pageid);
			if (f) f.info = p.imageinfo?.[0];
		}
	}
	return { files: [...byId.values()], warning: truncated ? `Wikimedia Commons ${LIMIT_HIT}.` : null };
}

const plain = (html: string | undefined) =>
	(html ?? '')
		.replace(/<[^>]+>/g, ' ')
		.replace(/&nbsp;/g, ' ')
		.replace(/&amp;/g, '&')
		.replace(/&quot;/g, '"')
		.replace(/&#0?39;/g, "'")
		.replace(/&lt;/g, '<')
		.replace(/&gt;/g, '>')
		.replace(/\s+/g, ' ')
		.trim();

const BROWSER_IMAGE = /^image\/(jpeg|png|gif|webp)$/;
const mediaType = (mime: string) =>
	/^image\/svg/.test(mime) ? 'drawing' : mime.startsWith('image/') ? 'photo' : mime === 'application/pdf' ? 'document' : mime.startsWith('video/') ? 'video' : mime.startsWith('audio/') ? 'audio' : 'other';

export function normalizeCommons(files: CommonsFile[], opts: { historicalOnly: boolean }): Candidate[] {
	const out: Candidate[] = [];
	for (const f of files) {
		const info = f.info;
		if (!info?.url) continue;
		const meta = info.extmetadata ?? {};
		const mime = info.mime ?? '';
		const taken = parseOsmDate(plain(meta.DateTimeOriginal?.value).match(/\d{4}(-\d{2}(-\d{2})?)?/)?.[0]);
		const circa = /\b(circa|ca\.?|c\.)\s*\d/i.test(plain(meta.DateTimeOriginal?.value));
		if (opts.historicalOnly && (!taken || +taken.date.slice(0, 4) > 1975)) continue;
		const title = f.title.replace(/^File:/, '').replace(/\.[A-Za-z0-9]{2,5}$/, '').replace(/_/g, ' ');
		const description = plain(meta.ImageDescription?.value);
		const creator = plain(meta.Artist?.value) || plain(meta.Credit?.value) || null;
		const rights = plain(meta.LicenseShortName?.value) || null;
		out.push({
			key: `commons:${f.pageid}`,
			origin: 'commons',
			kind: 'media',
			name: title.slice(0, 200),
			unnamed: false,
			summary: description ? description.slice(0, 600) : null,
			exists_from: taken?.date ?? null,
			exists_from_precision: taken?.precision ?? 'year',
			exists_to: null,
			exists_to_precision: 'year',
			approximate: circa || Boolean(taken?.approximate),
			geometry: point(f.lon, f.lat),
			geometry_source: 'commons',
			fact_source: 'commons',
			role: 'viewpoint',
			names: [],
			attributes: [],
			tags: [],
			ext: [{ source: 'commons', id: f.title, url: info.descriptionurl }],
			wikidata: null,
			image_url: null,
			media: {
				url: BROWSER_IMAGE.test(mime) || !info.thumburl ? info.url : info.thumburl,
				media_type: mediaType(mime),
				mime: mime || null,
				creator: creator?.slice(0, 200) ?? null,
				rights
			},
			classes: [mime || 'file'],
			raw: { title: f.title, mime, license: rights ?? '', creator: creator ?? '', thumb: info.thumburl ?? '' }
		});
	}
	return out;
}
