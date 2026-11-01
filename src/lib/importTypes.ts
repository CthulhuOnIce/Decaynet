import type { Precision } from './types';

export type ImportSource = 'ohm' | 'wikidata';

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
	};
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
	counts: { ohm: number; wikidata: number; combined: number; hiddenUnnamed: number };
	warnings: string[];
	items: PlanItem[];
}
