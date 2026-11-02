import { formatFuzzy, formatRange } from './time';
import type { Precision } from './types';

/** One proposed fix from timeline_plan() (see migration 0019). */
export interface TimelineFix {
	key: string;
	rule: TimelineRule;
	target: 'entity' | 'status' | 'geometry';
	op: 'update' | 'delete' | 'insert';
	id?: string;
	/** condition label, or the geometry role */
	label?: string;
	/** for close_overlap: the condition that starts next */
	next?: string | null;
	before?: FixRange;
	after?: FixRange;
}

export interface FixRange {
	valid_from: string | null;
	valid_from_precision: Precision;
	valid_to: string | null;
	valid_to_precision: Precision;
}

export type TimelineRule = 'end_lifespan' | 'merge_duplicate' | 'close_overlap' | 'close_at_end' | 'add_gone' | 'fit_footprint';

/** In the order fixes are applied; titles and explanations for reviewers. */
export const TIMELINE_RULES: Record<TimelineRule, { title: string; why: string }> = {
	end_lifespan: { title: 'End the lifespan', why: 'A “gone” condition is recorded, but the page still reads as standing.' },
	merge_duplicate: { title: 'Merge repeated conditions', why: 'The same condition twice in a row; the earlier one carries on.' },
	close_overlap: { title: 'Close overlapping conditions', why: 'A condition is still running when the next one starts.' },
	close_at_end: { title: 'End conditions with the lifespan', why: 'A standing condition runs past the end of the lifespan.' },
	add_gone: { title: 'Record how it ended', why: 'The lifespan ends but no condition says it was demolished (or vacated, for a street).' },
	fit_footprint: { title: 'Fit the footprint to the lifespan', why: 'The page has one footprint; it should cover the whole time the building stood.' }
};

export const ruleTitle = (r: string) => TIMELINE_RULES[r as TimelineRule]?.title ?? r;

const range = (r?: FixRange) => (r ? formatRange(r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision) || 'undated' : '');
const date = (d: string | null | undefined, p: Precision | undefined) => (d ? formatFuzzy(d, p ?? 'year') : 'open');

/** One line saying what the fix does. */
export function describeFix(f: TimelineFix): string {
	const a = f.after;
	switch (f.rule) {
		case 'end_lifespan':
			return `End the lifespan in ${date(a?.valid_to, a?.valid_to_precision)}, when it's recorded as “${f.label}”.`;
		case 'merge_duplicate':
			return f.op === 'delete'
				? `Remove the repeated “${f.label}” (${range(f.before)}).`
				: `“${f.label}” now runs ${range(a)}, covering its repeat.`;
		case 'close_overlap':
			return `End “${f.label}” in ${date(a?.valid_to, a?.valid_to_precision)}, when “${f.next}” begins.`;
		case 'close_at_end':
			return `End “${f.label}” in ${date(a?.valid_to, a?.valid_to_precision)}, when the lifespan ends.`;
		case 'add_gone':
			return `Add “${f.label}” from ${date(a?.valid_from, a?.valid_from_precision)}.`;
		case 'fit_footprint':
			return `Make the ${f.label ?? 'footprint'} cover ${range(a)}.`;
		default:
			return f.key;
	}
}

/** "1920 – open → 1920 – 1970" for fixes that change a range. */
export function fixChange(f: TimelineFix): string | null {
	if (f.op === 'insert' || f.op === 'delete' || !f.before || !f.after) return null;
	const b = range(f.before);
	const a = range(f.after);
	return b === a ? null : `${b} → ${a}`;
}
