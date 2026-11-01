/** Editable vocabularies (Admin → Vocabulary). Field definitions drive the generic editor. */
export type FieldType = 'text' | 'color' | 'number' | 'bool' | 'list' | 'select';
export interface Field {
	name: string;
	label: string;
	type: FieldType;
	options?: string[];
	wide?: boolean;
}
export interface VocabTable {
	table: string;
	title: string;
	help: string;
	fields: Field[];
	/** ids the application relies on: editable labels, but not deletable */
	core: string[];
}

const sort: Field = { name: 'sort', label: 'Order', type: 'number' };

export const VOCABS: VocabTable[] = [
	{
		table: 'entity_kinds',
		title: 'Page kinds',
		help: 'What a page can be. Verbs are used on timelines ("Built", "Founded", "Born"…).',
		fields: [
			{ name: 'label', label: 'Label', type: 'text' },
			{ name: 'plural', label: 'Plural', type: 'text' },
			{ name: 'color', label: 'Colour', type: 'color' },
			{ name: 'geometry_hint', label: 'Shape', type: 'select', options: ['', 'point', 'line', 'polygon'] },
			{ name: 'start_verb', label: 'Start verb', type: 'text' },
			{ name: 'end_verb', label: 'End verb', type: 'text' },
			{ name: 'description', label: 'Description', type: 'text', wide: true },
			sort
		],
		core: ['district', 'parcel', 'infrastructure', 'street', 'site', 'building', 'organization', 'person', 'event', 'media', 'water', 'landform', 'space']
	},
	{
		table: 'lifecycle_statuses',
		title: 'Conditions',
		help: 'The decay scale colours the map. Decay level 0 is healthy, 5 is gone; "extant" means something still stands.',
		fields: [
			{ name: 'label', label: 'Label', type: 'text' },
			{ name: 'color', label: 'Colour', type: 'color' },
			{ name: 'is_extant', label: 'Extant', type: 'bool' },
			{ name: 'decay_level', label: 'Decay 0–5', type: 'number' },
			{ name: 'description', label: 'Description', type: 'text', wide: true },
			sort
		],
		core: ['active', 'demolished', 'vacated', 'abandoned', 'ruin', 'restored']
	},
	{
		table: 'relation_types',
		title: 'Relationship types',
		help: 'How pages connect. Kinds lists limit which pages each side can be (comma-separated kind ids, blank = any).',
		fields: [
			{ name: 'label', label: 'Reads as', type: 'text' },
			{ name: 'inverse_label', label: 'Reverse reads as', type: 'text' },
			{ name: 'subject_kinds', label: 'From kinds', type: 'list' },
			{ name: 'object_kinds', label: 'To kinds', type: 'list' },
			{ name: 'description', label: 'Description', type: 'text', wide: true },
			sort
		],
		core: ['occupies', 'resides_at', 'owns', 'located_on', 'located_in', 'part_of', 'occurred_at', 'affected', 'participant', 'depicts', 'held_office', 'named_after', 'replaced']
	},
	{
		table: 'event_types',
		title: 'Event types',
		help: 'Kinds of events shown on the map and the chronology.',
		fields: [{ name: 'label', label: 'Label', type: 'text' }, { name: 'color', label: 'Colour', type: 'color' }, sort],
		core: ['other']
	},
	{
		table: 'attribute_keys',
		title: 'Attributes',
		help: 'Keyed facts with units, e.g. floors, height (ft or m), construction cost (USD, EUR…), a heritage register number.',
		fields: [
			{ name: 'label', label: 'Label', type: 'text' },
			{ name: 'value_type', label: 'Type', type: 'select', options: ['text', 'number', 'year', 'url', 'boolean'] },
			{ name: 'unit', label: 'Unit', type: 'text' },
			{ name: 'applies_to', label: 'Kinds', type: 'list' },
			sort
		],
		core: ['wikidata', 'floor', 'unit_label', 'architect', 'architectural_style', 'floors', 'height', 'material', 'nrhp_ref', 'website', 'industry', 'route_designation']
	},
	{
		table: 'article_statuses',
		title: 'Article statuses',
		help: 'Editorial workflow states. "Moderator only" statuses can only be set by moderators.',
		fields: [
			{ name: 'label', label: 'Label', type: 'text' },
			{ name: 'color', label: 'Colour', type: 'color' },
			{ name: 'moderator_only', label: 'Moderator only', type: 'bool' },
			{ name: 'description', label: 'Description', type: 'text', wide: true },
			sort
		],
		core: ['stub', 'draft', 'needs_sources', 'good', 'featured']
	},
	{
		table: 'tag_facets',
		title: 'Tag facets',
		help: 'Top-level groups in the tag tree. Add eras and themes that fit your region; edit the tags themselves on the Tags page.',
		fields: [
			{ name: 'label', label: 'Label', type: 'text' },
			{ name: 'color', label: 'Colour', type: 'color' },
			{ name: 'applies_to', label: 'Kinds', type: 'list' },
			{ name: 'description', label: 'Description', type: 'text', wide: true },
			sort
		],
		core: ['business_type', 'architecture', 'topic', 'media_subject', 'era']
	}
];
