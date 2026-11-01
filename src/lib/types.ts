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
	role: 'reader' | 'contributor' | 'moderator' | 'admin';
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
	repository: string | null;
	call_number: string | null;
	notes: string | null;
}

export interface MapLayer {
	id: string;
	title: string;
	tile_url: string;
	tile_size: number;
	attribution: string | null;
	depicts_from: string | null;
	depicts_to: string | null;
	min_zoom: number;
	max_zoom: number;
	bounds: [number, number, number, number] | null;
	default_opacity: number;
	enabled: boolean;
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
