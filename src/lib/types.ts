export type Precision = 'day' | 'month' | 'year' | 'decade' | 'century' | 'unknown';
export type Confidence = 'confirmed' | 'probable' | 'approximate' | 'speculative' | 'disputed';

export const PRECISIONS: Precision[] = ['day', 'month', 'year', 'decade', 'century', 'unknown'];
export const CONFIDENCES: Confidence[] = [
	'confirmed',
	'probable',
	'approximate',
	'speculative',
	'disputed'
];

export interface Profile {
	id: string;
	display_name: string;
	bio: string | null;
	role: string;
	suspended?: boolean;
	website?: string | null;
}

export interface EntityKind {
	id: string;
	label: string;
	plural: string;
	color: string;
	geometry_hint: 'point' | 'line' | 'polygon' | null;
	start_verb: string;
	end_verb: string;
	description: string | null;
	sort: number;
}

export interface LifecycleStatus {
	id: string;
	label: string;
	color: string;
	is_extant: boolean;
	decay_level: number;
	description: string | null;
}

export interface RelationType {
	id: string;
	label: string;
	inverse_label: string;
	subject_kinds: string[] | null;
	object_kinds: string[] | null;
	description: string | null;
}

export interface EventType {
	id: string;
	label: string;
	color: string;
}

export interface AttributeKey {
	id: string;
	label: string;
	value_type: 'text' | 'number' | 'year' | 'url' | 'boolean';
	unit: string | null;
	applies_to: string[] | null;
}

export interface ArticleStatus {
	id: string;
	label: string;
	color: string;
	description: string | null;
	moderator_only: boolean;
}

export interface Vocabulary {
	kinds: EntityKind[];
	statuses: LifecycleStatus[];
	relationTypes: RelationType[];
	eventTypes: EventType[];
	attributeKeys: AttributeKey[];
	articleStatuses: ArticleStatus[];
	tagFacets: TagFacet[];
}

export interface Entity {
	id: string;
	kind: string;
	slug: string;
	name: string;
	summary: string | null;
	exists_from: string | null;
	exists_from_precision: Precision;
	exists_to: string | null;
	exists_to_precision: Precision;
	lifespan_confidence: Confidence;
	is_private: boolean;
	published_at: string | null;
	created_by: string | null;
	created_at: string;
	updated_at: string;
}

/** Columns every component row shares (internal.temporal_fact). */
export interface TemporalFact {
	id: string;
	valid_from: string | null;
	valid_from_precision: Precision;
	valid_to: string | null;
	valid_to_precision: Precision;
	confidence: Confidence;
	source_id: string | null;
	source_detail: string | null;
	note: string | null;
	created_at: string;
}

export interface SourceRow {
	id: string;
	title: string;
	kind: string;
	author: string | null;
	publisher: string | null;
	published_on: string | null;
	published_precision: Precision;
	url: string | null;
	archive_url: string | null;
	/** archive_url was saved automatically (migration 0029) */
	archive_auto?: boolean;
	archive_checked_at?: string | null;
	archive_error?: string | null;
	repository: string | null;
	call_number: string | null;
	notes: string | null;
	/** page this source was made for; null = shared library */
	entity_id?: string | null;
}


export interface SnapshotRelation {
	direction: 'in' | 'out';
	predicate: string;
	label: string;
	id: string;
	slug: string;
	kind: string;
	name: string;
	qualifiers: Record<string, unknown>;
	valid_from: string | null;
	valid_from_precision: Precision;
	valid_to: string | null;
	valid_to_precision: Precision;
}

export interface EntitySnapshot {
	at: string;
	id: string;
	slug: string;
	kind: string;
	kind_label: string;
	canonical_name: string;
	name: string;
	summary: string | null;
	exists_from: string | null;
	exists_from_precision: Precision;
	exists_to: string | null;
	exists_to_precision: Precision;
	phase: 'past' | 'present' | 'future';
	status: { id: string; label: string; color: string; decay_level: number; is_extant: boolean } | null;
	address: string | null;
	other_names: {
		name: string;
		name_type: string;
		valid_from: string | null;
		valid_from_precision: Precision;
		valid_to: string | null;
		valid_to_precision: Precision;
		current: boolean;
	}[];
	attributes: { key: string; label: string; value: unknown; unit: string | null; value_type: string }[];
	relations: SnapshotRelation[];
	media: {
		id: string;
		slug: string;
		name: string;
		media_type: string;
		storage_path: string | null;
		external_url: string | null;
		captured: string | null;
		captured_precision: Precision;
	}[];
	article: {
		status: string;
		status_label: string;
		status_color: string;
		word_count: number;
		excerpt: string;
	} | null;
	location: { type: 'Point'; coordinates: [number, number] } | null;
}

export interface TimelineRow {
	at: string | null;
	at_precision: Precision;
	until: string | null;
	until_precision: Precision | null;
	category: string;
	label: string;
	ref_id: string | null;
	ref_slug: string | null;
	ref_kind: string | null;
	ref_name: string | null;
	fact_table: string;
	fact_id: string;
	confidence: Confidence;
	source_id: string | null;
	color: string;
	/** conditions: optional public context */
	description: string | null;
}

export interface RelationRow {
	id: string;
	direction: 'in' | 'out';
	predicate: string;
	label: string;
	other_id: string;
	other_slug: string;
	other_kind: string;
	other_name: string;
	other_name_then: string;
	qualifiers: Record<string, unknown>;
	valid_from: string | null;
	valid_from_precision: Precision;
	valid_to: string | null;
	valid_to_precision: Precision;
	confidence: Confidence;
	source_id: string | null;
	source_detail: string | null;
	note: string | null;
}

export interface ChronologyRow {
	at: string;
	at_precision: Precision;
	until: string | null;
	until_precision: Precision | null;
	category: 'event' | 'start' | 'end' | 'status';
	entity_id: string;
	slug: string;
	kind: string;
	name: string;
	label: string;
	subtype: string | null;
	color: string;
	/** conditions: optional public context */
	description: string | null;
}

export interface SearchHit {
	id: string;
	slug: string;
	kind: string;
	name: string;
	matched_name: string;
	exists_from: string | null;
	exists_to: string | null;
	score: number;
}

/** A street address matched by the global search. */
export interface AddressHit {
	address_id: string;
	entity_id: string;
	entity_slug: string;
	entity_kind: string;
	entity_name: string;
	street_id: string | null;
	street_name: string | null;
	house_number: string | null;
	raw_address: string | null;
	formatted: string;
	lon: number | null;
	lat: number | null;
	score: number;
}

/** An address geocoded from OpenStreetMap that may not exist in this wiki yet. */
export interface GeoAddressHit {
	place_id: number;
	/** Short form: "577 Washington St" */
	label: string;
	display_name: string;
	lat: number;
	lon: number;
	house_number: string | null;
	street: string | null;
	locality: string | null;
}

/** A feature the user clicked on the time-machine map. */
export interface Picked {
	id: string;
	slug: string;
	kind: string;
	name: string;
}

export interface TagFacet {
	id: string;
	label: string;
	description: string | null;
	applies_to: string[] | null;
	color: string;
}

/** Row of the tag_index view: a tag with its full path and usage counts. */
export interface TagRow {
	id: string;
	slug: string;
	label: string;
	facet: string;
	facet_label: string;
	color: string;
	parent_id: string | null;
	description: string | null;
	path: string;
	depth: number;
	direct_uses: number;
	total_uses: number;
}

/** Row of tags_at(): a tag on an entity, possibly implied by a more specific sub-trait. */
export interface EntityTag {
	tag_id: string;
	slug: string;
	label: string;
	facet: string;
	facet_label: string;
	color: string;
	path: string;
	implied: boolean;
	valid_from: string | null;
	valid_from_precision: Precision;
	valid_to: string | null;
	valid_to_precision: Precision;
	fact_id: string | null;
}

export type Permission =
	| 'edit_content'
	| 'upload_media'
	| 'view_private'
	| 'create_tags'
	| 'review_tips'
	| 'bulk_edit'
	| 'moderate'
	| 'clean_timelines'
	| 'manage_users'
	| 'manage_settings';

/** Permissions that open the admin area (each section checks its own). */
export const ADMIN_PERMS: Permission[] = ['manage_users', 'manage_settings', 'moderate', 'clean_timelines'];

export interface SiteSettings {
	site_name: string;
	tagline: string;
	region_name: string;
	about: string;
	map_center_lon: number;
	map_center_lat: number;
	map_zoom: number;
	default_year: number;
	min_year: number;
	basemap_url: string;
	basemap_attribution: string;
	basemap_mode: 'fade' | 'always' | 'hidden';
	allow_signups: boolean;
	default_role: string;
	tips_enabled: boolean;
	tips_intro: string;
	tips_allow_images: boolean;
	tips_max_images: number;
	tips_max_image_mb: number;
	tips_ip_mode: 'off' | 'hash' | 'full';
	tips_captcha_provider: 'none' | 'turnstile' | 'hcaptcha';
	tips_captcha_site_key: string | null;
	tips_rate_limit_per_hour: number;
	source_code_url: string;
	units: 'metric' | 'imperial';
	address_format: 'number_street' | 'street_number';
	content_language: string;
	/** [west, south, east, north] or null for the whole world */
	map_bounds: [number, number, number, number] | null;
	setup_complete: boolean;
	new_pages_private: boolean;
	/** save source links to the Internet Archive (migration 0029) */
	archive_sources?: boolean;
	/** map colour for plotted buildings with no condition yet; null = off (migration 0038) */
	unstated_color?: string | null;
	/** how page timelines are drawn (migration 0034) */
	timeline_style?: 'table' | 'bubbles';
	updated_at: string;
}

export interface Space {
	id: string;
	slug: string;
	name: string;
	floor: number | null;
	unit_label: string | null;
	geojson: GeoJSON.Polygon | GeoJSON.MultiPolygon | null;
	tenants: string | null;
	present: boolean;
	exists_from: string | null;
	exists_from_precision: Precision;
	exists_to: string | null;
	exists_to_precision: Precision;
}
