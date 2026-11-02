import type { Precision } from './types';

export type ImportSource = 'ohm' | 'wikidata' | 'osm' | 'wikipedia' | 'commons' | 'geonames';

/** Facts the Wikidata importer can pull; each can be switched off in the importer. */
export const WIKIDATA_FIELDS = [
	{ id: 'dates', label: 'Start & end dates' },
	{ id: 'aliases', label: 'Alternate names' },
	{ id: 'architect', label: 'Architect' },
	{ id: 'style', label: 'Architectural style' },
	{ id: 'floors', label: 'Floors' },
	{ id: 'height', label: 'Height' },
	{ id: 'material', label: 'Material' },
	{ id: 'capacity', label: 'Capacity' },
	{ id: 'nrhp', label: 'NRHP reference' },
	{ id: 'website', label: 'Website' },
	{ id: 'owner', label: 'Owner' },
	{ id: 'use', label: 'Use' },
	{ id: 'industry', label: 'Industry' },
	{ id: 'employees', label: 'Employees' },
	{ id: 'population', label: 'Population' },
	{ id: 'lanes', label: 'Lanes' },
	{ id: 'casualties', label: 'Casualties' }
] as const;
export type WikidataField = (typeof WIKIDATA_FIELDS)[number]['id'];

export interface ImportOptions {
	/** [west, south, east, north] */
	bbox: [number, number, number, number];
	ohm: {
		enabled: boolean;
		buildings: boolean;
		unnamedBuildings: boolean;
		streets: boolean;
		railways: boolean;
		water: boolean;
		businesses: boolean;
		places: boolean;
	};
	wikidata: {
		enabled: boolean;
		images: boolean;
		/** missing entries count as on */
		fields: Partial<Record<WikidataField, boolean>>;
	};
	/** Current OpenStreetMap: things that (probably) still exist */
	osm: { enabled: boolean; businesses: boolean; places: boolean; buildings: boolean };
	wikipedia: { enabled: boolean };
	commons: { enabled: boolean; historicalOnly: boolean };
	geonames: { enabled: boolean };
}

export interface CandidateMedia {
	url: string;
	media_type: string;
	mime: string | null;
	creator: string | null;
	rights: string | null;
}

/** A fetched, normalized feature ready to become (or enrich) a page. */
export interface Candidate {
	key: string;
	origin: ImportSource | 'both';
	kind: string;
	name: string;
	unnamed: boolean;
	summary: string | null;
	exists_from: string | null;
	exists_from_precision: Precision;
	exists_to: string | null;
	exists_to_precision: Precision;
	approximate: boolean;
	geometry: GeoJSON.Geometry | null;
	geometry_source: ImportSource | null;
	/** where lifespan / condition / tags come from (for citations) */
	fact_source: ImportSource;
	role: string;
	names: { name: string; name_type: string; source: ImportSource }[];
	attributes: { key: string; value: unknown; source: ImportSource }[];
	tags: string[];
	ext: { source: ImportSource; id: string; url: string }[];
	wikidata: string | null;
	image_url: string | null;
	/** a standalone file (Commons): becomes a media page */
	media?: CandidateMedia;
	/** lifecycle status to record (only when the source says so) */
	status?: string | null;
	classes: string[];
	/** for events: a guessed event type id (used only if the site has it) */
	event_type?: string | null;
	/** problems found while normalizing, shown in the preview */
	issues?: string[];
	/** raw source tags, for the "details" disclosure in the preview */
	raw: Record<string, string>;
}

export interface MatchInfo {
	entity_id: string;
	slug: string;
	name: string;
	kind: string;
	reason: string;
	exists_from: string | null;
	exists_to: string | null;
	has_shape: boolean;
	has_geometry: boolean;
	has_status: boolean;
	summary: string | null;
	names: string[];
	attributes: string[];
	tags: string[];
	ext: string[];
}

export type PlanAction = 'create' | 'merge' | 'skip';

export interface PlanItem {
	key: string;
	candidate: Candidate;
	match: MatchInfo | null;
	action: PlanAction;
	/** human-readable list of what applying this row will do */
	changes: string[];
	/** for merges: whether the shape will be added (only default-on when the page has none) */
	addShape: boolean;
}

export interface PreviewResult {
	bbox: [number, number, number, number];
	fetchedAt: string;
	counts: { ohm: number; osm: number; wikidata: number; wikipedia: number; geonames: number; commons: number; combined: number; hiddenUnnamed: number };
	warnings: string[];
	items: PlanItem[];
}
