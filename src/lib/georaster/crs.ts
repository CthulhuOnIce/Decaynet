/*
 * Coordinate systems a georeferenced scan can come in, as proj4 definitions (checked against
 * the EPSG database). The ones Gary-area imagery uses are built in; any other can be pasted.
 */
import proj4 from 'proj4';

export interface Crs {
	/** "EPSG:2966", or "custom" for a pasted definition */
	id: string;
	label: string;
	/** proj4 string or WKT */
	def: string;
}

// NAD27 is shifted to WGS 84 with the CONUS mean (EPSG:1173, a few metres): proj4 in the
// browser has no NADCON grids
const NAD27 = '+ellps=clrk66 +towgs84=-8,160,176,0,0,0,0';
const W = '+proj=tmerc +lat_0=37.5 +lon_0=-87.0833333333333 +k=0.999966667';
const E = '+proj=tmerc +lat_0=37.5 +lon_0=-85.6666666666667 +k=0.999966667';
const INGCS = (lat: number, lon: number, k: number) => `+proj=tmerc +lat_0=${lat} +lon_0=${lon} +k=${k} +x_0=240000 +y_0=36000 +ellps=GRS80`;

export const CRS_PRESETS: Crs[] = [
	{ id: 'EPSG:4326', label: 'Longitude / latitude (WGS 84)', def: '+proj=longlat +datum=WGS84 +no_defs' },
	{ id: 'EPSG:4269', label: 'Longitude / latitude (NAD83)', def: '+proj=longlat +datum=NAD83 +no_defs' },
	{ id: 'EPSG:3857', label: 'Web Mercator', def: '+proj=merc +a=6378137 +b=6378137 +lat_ts=0 +lon_0=0 +x_0=0 +y_0=0 +k=1 +units=m +nadgrids=@null +no_defs' },
	{ id: 'EPSG:26916', label: 'UTM zone 16N (NAD83, metres)', def: '+proj=utm +zone=16 +datum=NAD83 +units=m +no_defs' },
	{ id: 'EPSG:32616', label: 'UTM zone 16N (WGS 84, metres)', def: '+proj=utm +zone=16 +datum=WGS84 +units=m +no_defs' },
	{ id: 'EPSG:26716', label: 'UTM zone 16N (NAD27, metres)', def: `+proj=utm +zone=16 ${NAD27} +units=m +no_defs` },
	{ id: 'EPSG:2966', label: 'Indiana West (NAD83, US feet)', def: `${W} +x_0=900000 +y_0=249999.9998984 +datum=NAD83 +units=us-ft +no_defs` },
	{ id: 'EPSG:26974', label: 'Indiana West (NAD83, metres)', def: `${W} +x_0=900000 +y_0=250000 +datum=NAD83 +units=m +no_defs` },
	{ id: 'EPSG:2965', label: 'Indiana East (NAD83, US feet)', def: `${E} +x_0=99999.9998983998 +y_0=249999.9998984 +datum=NAD83 +units=us-ft +no_defs` },
	{ id: 'EPSG:26973', label: 'Indiana East (NAD83, metres)', def: `${E} +x_0=100000 +y_0=250000 +datum=NAD83 +units=m +no_defs` },
	{ id: 'EPSG:26774', label: 'Indiana West (NAD27, US feet)', def: `${W} +x_0=152400.30480061 +y_0=0 ${NAD27} +units=us-ft +no_defs` },
	{ id: 'EPSG:26773', label: 'Indiana East (NAD27, US feet)', def: `${E} +x_0=152400.30480061 +y_0=0 ${NAD27} +units=us-ft +no_defs` },
	{ id: 'EPSG:7334', label: 'InGCS Lake-Newton (US feet)', def: `${INGCS(40.7, -87.4, 1.000026)} +units=us-ft +no_defs` },
	{ id: 'EPSG:7333', label: 'InGCS Lake-Newton (metres)', def: `${INGCS(40.7, -87.4, 1.000026)} +units=m +no_defs` },
	{ id: 'EPSG:7320', label: 'InGCS Jasper-Porter (US feet)', def: `${INGCS(40.7, -87.1, 1.000027)} +units=us-ft +no_defs` },
	{ id: 'EPSG:7319', label: 'InGCS Jasper-Porter (metres)', def: `${INGCS(40.7, -87.1, 1.000027)} +units=m +no_defs` },
	{ id: 'EPSG:7336', label: 'InGCS LaPorte-Pulaski-Starke (US feet)', def: `${INGCS(40.9, -86.75, 1.000027)} +units=us-ft +no_defs` }
];

/** The same zones under other datum realisations (HARN, NSRS2007, 2011): the same projection to within a metre or two. */
const ALIASES: Record<number, string> = {
	2968: 'EPSG:2966', 3535: 'EPSG:2966', 6461: 'EPSG:2966',
	2793: 'EPSG:26974', 3534: 'EPSG:26974', 6460: 'EPSG:26974',
	2967: 'EPSG:2965', 3533: 'EPSG:2965', 6459: 'EPSG:2965',
	2792: 'EPSG:26973', 3532: 'EPSG:26973', 6458: 'EPSG:26973',
	4258: 'EPSG:4326', 4152: 'EPSG:4269', 6318: 'EPSG:4269', 900913: 'EPSG:3857', 3785: 'EPSG:3857', 102100: 'EPSG:3857',
	6345: 'EPSG:26916', 3745: 'EPSG:26916', 3720: 'EPSG:26916'
};

/** What ESRI calls the built-in systems in a .prj (which has no EPSG code). */
const ESRI_NAMES: Record<string, string> = {
	gcs_wgs_1984: 'EPSG:4326',
	gcs_north_american_1983: 'EPSG:4269',
	wgs_1984_web_mercator_auxiliary_sphere: 'EPSG:3857',
	wgs_1984_web_mercator: 'EPSG:3857',
	nad_1983_utm_zone_16n: 'EPSG:26916',
	wgs_1984_utm_zone_16n: 'EPSG:32616',
	nad_1927_utm_zone_16n: 'EPSG:26716',
	nad_1983_stateplane_indiana_west_fips_1302_feet: 'EPSG:2966',
	nad_1983_stateplane_indiana_west_fips_1302: 'EPSG:26974',
	nad_1983_stateplane_indiana_east_fips_1301_feet: 'EPSG:2965',
	nad_1983_stateplane_indiana_east_fips_1301: 'EPSG:26973',
	nad_1983_harn_stateplane_indiana_west_fips_1302_feet: 'EPSG:2966',
	nad_1983_2011_stateplane_indiana_west_fips_1302_ft_us: 'EPSG:2966',
	nad_1927_stateplane_indiana_west_fips_1302: 'EPSG:26774',
	nad_1927_stateplane_indiana_east_fips_1301: 'EPSG:26773',
	nad_1983_2011_ingcs_lake_newton_ftus: 'EPSG:7334',
	nad_1983_2011_ingcs_lake_newton_m: 'EPSG:7333',
	nad_1983_2011_ingcs_jasper_porter_ftus: 'EPSG:7320',
	nad_1983_2011_ingcs_jasper_porter_m: 'EPSG:7319'
};

/** A coordinate system from an EPSG code, if it's one Decaynet knows. */
export function crsFromEpsg(code: number): Crs | null {
	const id = ALIASES[code] ?? `EPSG:${code}`;
	return CRS_PRESETS.find((c) => c.id === id) ?? null;
}

/** A pasted definition (proj4 string or WKT, e.g. a .prj file's text), if proj4 can use it. */
export function crsFromText(text: string, label = 'From its .prj file'): Crs | null {
	const def = text.trim();
	if (!def) return null;
	// an EPSG code on its own ("EPSG:2966", "2966")
	const code = def.match(/^(?:EPSG:)?(\d{4,6})$/i);
	if (code) return crsFromEpsg(Number(code[1]));
	// a .prj that names a known EPSG system
	const auth = def.match(/AUTHORITY\["EPSG",\s*"(\d+)"\]\s*\]\s*$/i) ?? def.match(/ID\["EPSG",\s*(\d+)\]\s*\]\s*$/i);
	if (auth) {
		const known = crsFromEpsg(Number(auth[1]));
		if (known) return known;
	}
	// an ESRI .prj names its system but carries no EPSG code
	const name = def.match(/^\s*(?:PROJCS|GEOGCS|PROJCRS|GEOGCRS)\["([^"]+)"/i)?.[1];
	if (name) {
		const known = ESRI_NAMES[name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '')];
		if (known) return CRS_PRESETS.find((c) => c.id === known) ?? null;
	}
	try {
		proj4(def, 'EPSG:4326', [0, 0]);
		return { id: 'custom', label: name ? name.replace(/_/g, ' ') : label, def };
	} catch {
		return null;
	}
}

/** [x, y] in the system → [lng, lat], or null when it doesn't come out as a place on Earth. */
export function toLngLat(crs: Crs, xy: [number, number]): [number, number] | null {
	try {
		const [lng, lat] = proj4(crs.def, 'EPSG:4326', xy) as [number, number];
		return Number.isFinite(lng) && Number.isFinite(lat) && Math.abs(lng) <= 180 && Math.abs(lat) <= 90 ? [lng, lat] : null;
	} catch {
		return null;
	}
}

/**
 * With no .prj and no EPSG code (a bare world file): the built-in system that puts the image
 * nearest the place you're working on (the map's centre), if any lands within ~300 km.
 */
export function guessCrs(xy: [number, number], near: [number, number]): Crs | null {
	const km = ([a, b]: [number, number], [c, d]: [number, number]) => {
		const r = Math.PI / 180;
		const h = Math.sin(((d - b) * r) / 2) ** 2 + Math.cos(b * r) * Math.cos(d * r) * Math.sin(((c - a) * r) / 2) ** 2;
		return 2 * 6371 * Math.asin(Math.sqrt(h));
	};
	let best: { c: Crs; d: number } | null = null;
	for (const c of CRS_PRESETS) {
		const ll = toLngLat(c, xy);
		if (!ll) continue;
		const d = km(ll, near);
		// datums of one projection land metres apart: keep the first listed unless another is clearly nearer
		if (d < 300 && (!best || d < best.d - 1)) best = { c, d };
	}
	return best?.c ?? null;
}
