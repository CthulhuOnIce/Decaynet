import type { Candidate, ImportOptions } from '$lib/importTypes';
import { parseWikidataTime } from './dates';

export const WIKIDATA_SPARQL = 'https://query.wikidata.org/sparql';

const SELECT = `
SELECT ?item ?itemLabel ?itemDescription ?coord
       (GROUP_CONCAT(DISTINCT ?instLabel; separator="|") AS ?classes)
       (SAMPLE(?inc) AS ?inception) (SAMPLE(?incP) AS ?inceptionPrec)
       (SAMPLE(?end) AS ?ended) (SAMPLE(?endP) AS ?endedPrec)
       (SAMPLE(?img) AS ?image) (SAMPLE(?nrhp) AS ?nrhpRef)
       (SAMPLE(?archLabel) AS ?architect) (SAMPLE(?styleLabel) AS ?style)
       (SAMPLE(?floors) AS ?floorCount) (SAMPLE(?web) AS ?website)
       (GROUP_CONCAT(DISTINCT ?alias; separator="|") AS ?aliases)
WHERE {
  %SCOPE%
  OPTIONAL { ?item wdt:P31 ?inst . ?inst rdfs:label ?instLabel . FILTER(LANG(?instLabel) = "en") }
  OPTIONAL { ?item p:P571/psv:P571 [ wikibase:timeValue ?inc ; wikibase:timePrecision ?incP ] }
  OPTIONAL { ?item p:P576/psv:P576 [ wikibase:timeValue ?end ; wikibase:timePrecision ?endP ] }
  OPTIONAL { ?item wdt:P18 ?img }
  OPTIONAL { ?item wdt:P649 ?nrhp }
  OPTIONAL { ?item wdt:P84 ?arch . ?arch rdfs:label ?archLabel . FILTER(LANG(?archLabel) = "en") }
  OPTIONAL { ?item wdt:P149 ?st . ?st rdfs:label ?styleLabel . FILTER(LANG(?styleLabel) = "en") }
  OPTIONAL { ?item wdt:P1101 ?floors }
  OPTIONAL { ?item wdt:P856 ?web }
  OPTIONAL { ?item skos:altLabel ?alias . FILTER(LANG(?alias) = "en") }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
GROUP BY ?item ?itemLabel ?itemDescription ?coord
LIMIT 2000`;

type Binding = Record<string, { value: string } | undefined>;

async function sparql(query: string, userAgent: string): Promise<Binding[]> {
	const res = await fetch(WIKIDATA_SPARQL, {
		method: 'POST',
		headers: {
			'content-type': 'application/x-www-form-urlencoded',
			accept: 'application/sparql-results+json',
			'user-agent': userAgent
		},
		body: new URLSearchParams({ query }),
		signal: AbortSignal.timeout(60_000)
	});
	if (!res.ok) throw new Error(`Wikidata query service returned ${res.status}`);
	const json = (await res.json()) as { results: { bindings: Binding[] } };
	return json.results.bindings;
}

/** Items with coordinates inside the box. */
export function fetchWikidataBox(bbox: ImportOptions['bbox'], userAgent: string) {
	const [w, s, e, n] = bbox;
	const scope = `SERVICE wikibase:box {
    ?item wdt:P625 ?coord .
    bd:serviceParam wikibase:cornerSouthWest "Point(${w} ${s})"^^geo:wktLiteral .
    bd:serviceParam wikibase:cornerNorthEast "Point(${e} ${n})"^^geo:wktLiteral .
  }`;
	return sparql(SELECT.replace('%SCOPE%', scope), userAgent);
}

/** Specific items (e.g. ones an OHM feature points at with a wikidata=* tag). */
export function fetchWikidataItems(qids: string[], userAgent: string) {
	if (!qids.length) return Promise.resolve([] as Binding[]);
	const scope = `VALUES ?item { ${qids.map((q) => `wd:${q}`).join(' ')} } OPTIONAL { ?item wdt:P625 ?coord }`;
	return sparql(SELECT.replace('%SCOPE%', scope), userAgent);
}

// ----------------------------------------------------------------------------- classification

/** Broad administrative or abstract things that don't make good map pages. */
const SKIP = /\b(city|town|township|county|state|diocese|school district|radio station|television station|parish|census|human|congressional|unincorporated community|metropolitan area|zip code|electoral)\b/i;

function kindFor(classes: string[]): string | null {
	const c = classes.join(' | ').toLowerCase();
	if (!c) return 'site';
	if (SKIP.test(c) && !/neighbo|building|station|church|school/.test(c)) return null;
	if (/neighbo|district|quarter|historic district|planned community|subdivision/.test(c)) return 'district';
	if (/street|road|avenue|boulevard|highway|expressway|toll road/.test(c)) return /highway|expressway|toll road|interstate/.test(c) ? 'infrastructure' : 'street';
	if (/river|lake|lagoon|canal|creek|harbor|harbour|bay|wetland/.test(c)) return 'water';
	if (/dune|beach|forest|woods|hill/.test(c)) return /beach|forest|woods/.test(c) ? 'site' : 'landform';
	if (/railway line|railroad|bridge|interurban|pier|dam/.test(c)) return 'infrastructure';
	if (/park|cemetery|stadium|venue|ballpark|garden|square|plaza/.test(c)) return /stadium|venue|ballpark/.test(c) ? 'building' : 'site';
	if (/company|business|enterprise|corporation|organization|congregation|newspaper|club|union/.test(c) && !/building|factory|plant|works/.test(c)) return 'organization';
	if (/event|strike|riot|fire\b|disaster|election/.test(c)) return 'event';
	return 'building';
}

function tagSlugs(classes: string[]): string[] {
	const c = classes.join(' | ').toLowerCase();
	const out = new Set<string>();
	if (/church|cathedral|chapel|synagogue|mosque|temple/.test(c)) out.add(/church|cathedral|chapel/.test(c) ? 'church' : 'religious');
	if (/school|college|university|academy/.test(c)) out.add('school');
	if (/hotel|motel|inn\b/.test(c)) out.add('hotel');
	if (/movie theater|cinema/.test(c)) out.add('movie-theater');
	if (/theater|theatre|auditorium|arena|venue|stadium/.test(c)) out.add('entertainment');
	if (/railway station|train station|union station/.test(c)) out.add('rail-station');
	if (/steel|factory|plant|mill|works/.test(c)) out.add(/steel/.test(c) ? 'steel' : 'industrial');
	if (/city hall|town hall|courthouse|fire station|post office|library|police/.test(c)) out.add('civic');
	if (/department store/.test(c)) out.add('department-store');
	if (/beaux-arts/.test(c)) out.add('beaux-arts');
	if (/gothic revival/.test(c)) out.add('gothic-revival');
	if (/art deco/.test(c)) out.add('art-deco');
	if (/neoclassical/.test(c)) out.add('neoclassical');
	return [...out];
}

const val = (b: Binding, k: string) => b[k]?.value;
const pointOf = (wkt: string | undefined): GeoJSON.Point | null => {
	const m = wkt?.match(/Point\(([-\d.]+) ([-\d.]+)\)/);
	return m ? { type: 'Point', coordinates: [+(+m[1]).toFixed(7), +(+m[2]).toFixed(7)] } : null;
};

export function normalizeWikidata(rows: Binding[], opts: { images: boolean }): Candidate[] {
	const seen = new Set<string>();
	const out: Candidate[] = [];
	for (const r of rows) {
		const qid = val(r, 'item')?.split('/').pop();
		if (!qid || seen.has(qid)) continue;
		seen.add(qid);
		const label = val(r, 'itemLabel');
		if (!label || label === qid) continue;
		const classes = (val(r, 'classes') ?? '').split('|').filter(Boolean);
		const style = val(r, 'style');
		const kind = kindFor(classes);
		if (!kind) continue;
		const from = parseWikidataTime(val(r, 'inception'), val(r, 'inceptionPrec'));
		const to = parseWikidataTime(val(r, 'ended'), val(r, 'endedPrec'));
		const attributes: Candidate['attributes'] = [{ key: 'wikidata', value: qid, source: 'wikidata' }];
		if (val(r, 'nrhpRef')) attributes.push({ key: 'nrhp_ref', value: val(r, 'nrhpRef'), source: 'wikidata' });
		if (val(r, 'architect')) attributes.push({ key: 'architect', value: val(r, 'architect'), source: 'wikidata' });
		if (style) attributes.push({ key: 'architectural_style', value: style, source: 'wikidata' });
		if (val(r, 'floorCount') && Number.isFinite(+val(r, 'floorCount')!)) attributes.push({ key: 'floors', value: +val(r, 'floorCount')!, source: 'wikidata' });
		if (val(r, 'website')) attributes.push({ key: 'website', value: val(r, 'website'), source: 'wikidata' });
		const names = (val(r, 'aliases') ?? '')
			.split('|')
			.filter((a) => a && a.toLowerCase() !== label.toLowerCase())
			.slice(0, 6)
			.map((a) => ({ name: a, name_type: 'alternate', source: 'wikidata' as const }));
		const point = pointOf(val(r, 'coord'));
		out.push({
			key: `wikidata:${qid}`,
			origin: 'wikidata',
			kind,
			name: label,
			unnamed: false,
			summary: val(r, 'itemDescription') ?? null,
			exists_from: from?.date ?? null,
			exists_from_precision: from?.precision ?? 'year',
			exists_to: to?.date ?? null,
			exists_to_precision: to?.precision ?? 'year',
			approximate: false,
			geometry: point,
			geometry_source: point ? 'wikidata' : null,
			fact_source: 'wikidata',
			role: 'point',
			names,
			attributes,
			tags: tagSlugs([...classes, style ?? '']),
			ext: [{ source: 'wikidata', id: qid, url: `https://www.wikidata.org/wiki/${qid}` }],
			wikidata: qid,
			image_url: opts.images ? (val(r, 'image') ?? null) : null,
			classes,
			raw: Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v?.value ?? ''])) as Record<string, string>
		});
	}
	return out;
}
