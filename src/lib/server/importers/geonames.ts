import type { Candidate, ImportOptions } from '$lib/importTypes';
import { tagSlugs } from './wikidata';

interface GeoName {
	geonameId: number;
	name: string;
	toponymName?: string;
	lat: string;
	lng: string;
	fcl?: string;
	fcode?: string;
	fcodeName?: string;
	population?: number;
	adminName1?: string;
	adminName2?: string;
	countryName?: string;
	alternateNames?: { name: string; lang?: string }[];
}

const SKIPPED_ALT_LANGS = new Set(['link', 'post', 'iata', 'icao', 'faac', 'faac', 'tcid', 'unlc', 'abbr', 'wkdt', 'fr_1793', 'nuts', 'phon', 'piny']);

export async function fetchGeonames(bbox: ImportOptions['bbox'], userAgent: string, lang: string, username: string) {
	const [w, s, e, n] = bbox;
	const params = new URLSearchParams({
		north: String(n), south: String(s), east: String(e), west: String(w),
		maxRows: '1000', style: 'FULL', lang: /^[a-z]{2,3}$/i.test(lang) ? lang.toLowerCase() : 'en', username
	});
	for (const c of ['P', 'S', 'H', 'T', 'L', 'R', 'V']) params.append('featureClass', c);
	const res = await fetch(`https://secure.geonames.org/searchJSON?${params}`, {
		headers: { 'user-agent': userAgent, accept: 'application/json' },
		signal: AbortSignal.timeout(30_000)
	});
	if (!res.ok) throw new Error(`GeoNames returned ${res.status}`);
	const json = (await res.json()) as { geonames?: GeoName[]; totalResultsCount?: number; status?: { message: string } };
	if (json.status) throw new Error(`GeoNames: ${json.status.message}`);
	const rows = json.geonames ?? [];
	return { rows, truncated: (json.totalResultsCount ?? 0) > rows.length };
}

const BUILDINGS = new Set(['BLDG', 'HSE', 'CH', 'MSTY', 'SCH', 'SCHC', 'UNIV', 'LIBR', 'HSP', 'HTL', 'THTR', 'MUS', 'OPRA', 'PO', 'PSTB', 'CTHSE', 'BANK', 'FIRE', 'PP', 'PRN', 'HSEC', 'CSTL', 'TOWR', 'LTHSE', 'MALL', 'STDM', 'AIRB', 'RSTN', 'MFG', 'FCL', 'FRM', 'CTRM', 'CTRR', 'CTRA', 'ARCH']);
const INFRA = new Set(['BDG', 'DAM', 'TNL', 'PIER', 'RR', 'RDJCT', 'CSWY', 'LOCK', 'RSTP', 'WHRF', 'DKS', 'CNLSB']);
const SITES = new Set(['HSTS', 'MNMT', 'CMTY', 'PRK', 'PRKGT', 'PRKHQ', 'RSRT', 'RUIN', 'RUINS', 'ZOO', 'CMN', 'SQR', 'PLAZ', 'GDN']);

function kindFor(g: GeoName): string | null {
	const code = g.fcode ?? '';
	switch (g.fcl) {
		case 'P':
			return /^(PPLX|PPLH|PPLQ|PPLL|PPLW)$/.test(code) ? 'district' : null; // skip whole towns and cities
		case 'H':
			return 'water';
		case 'T':
			return 'landform';
		case 'V':
			return 'site';
		case 'L':
			return code === 'LCTY' || code === 'LCTYH' ? 'district' : 'site';
		case 'R':
			return INFRA.has(code) ? 'infrastructure' : /^(RD|RDA|ST|STNB|TRL|PASS)/.test(code) ? 'street' : 'infrastructure';
		case 'S':
			return INFRA.has(code) ? 'infrastructure' : SITES.has(code) ? 'site' : BUILDINGS.has(code) ? 'building' : 'site';
		default:
			return null;
	}
}

export function normalizeGeonames(rows: GeoName[], lang: string): Candidate[] {
	const out: Candidate[] = [];
	for (const g of rows) {
		const kind = kindFor(g);
		const lat = +g.lat;
		const lon = +g.lng;
		if (!kind || !g.name || !Number.isFinite(lat) || !Number.isFinite(lon)) continue;
		const where = [g.adminName2, g.adminName1, g.countryName].filter(Boolean).join(', ');
		const label = g.fcodeName || null;
		const seen = new Set([g.name.toLowerCase()]);
		const names: Candidate['names'] = [];
		const add = (name: string | undefined) => {
			if (name && !seen.has(name.toLowerCase())) {
				seen.add(name.toLowerCase());
				names.push({ name, name_type: 'alternate', source: 'geonames' });
			}
		};
		add(g.toponymName);
		for (const a of g.alternateNames ?? []) if (!a.lang || (!SKIPPED_ALT_LANGS.has(a.lang) && (a.lang === lang || a.lang === 'en'))) add(a.name);
		const attributes: Candidate['attributes'] = [];
		if (kind === 'district' && g.population && g.population > 0) attributes.push({ key: 'population', value: g.population, source: 'geonames' });
		out.push({
			key: `geonames:${g.geonameId}`,
			origin: 'geonames',
			kind,
			name: g.name.slice(0, 200),
			unnamed: false,
			summary: label ? `${label}${where ? ` in ${where}` : ''}.` : null,
			exists_from: null,
			exists_from_precision: 'year',
			exists_to: null,
			exists_to_precision: 'year',
			approximate: false,
			geometry: { type: 'Point', coordinates: [+lon.toFixed(7), +lat.toFixed(7)] },
			geometry_source: 'geonames',
			fact_source: 'geonames',
			role: 'point',
			names: names.slice(0, 6),
			attributes,
			tags: tagSlugs(label ? [label] : []),
			ext: [{ source: 'geonames', id: String(g.geonameId), url: `https://www.geonames.org/${g.geonameId}` }],
			wikidata: null,
			image_url: null,
			classes: label ? [label] : [],
			raw: { fcode: g.fcode ?? '', feature: label ?? '', population: String(g.population ?? '') }
		});
	}
	return out;
}
