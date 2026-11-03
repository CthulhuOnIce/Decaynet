import { formatFuzzy, formatRange } from './time';
import type { Precision } from './types';

/** One item from timeline_plan() (see migration 0019). */
export interface TimelineFix {
	key: string;
	op: 'update' | 'insert' | 'delete' | 'note';
	rule: string;
	section: TimelineSection;
	table: string;
	id?: string;
	/** condition label, shape role, address, name, "occupied by X", ... */
	label?: string;
	/** the condition that starts next (close_overlap, close_gap, fill_active) */
	next?: string | null;
	/** for inserted conditions */
	status?: string;
	/** reasons for a range change: start, end, open, overlap, gap, end_of_use, construction, or condition rules */
	why?: string[];
	/** relations: which end(s) the item changes */
	sets?: ('start' | 'end')[];
	/** relations ending with use: the condition that ends it ("Vacant") */
	use?: string | null;
	before?: FixRange;
	after?: FixRange;
	/** on by default; off = a suggestion a person should confirm */
	default: boolean;
}

export interface FixRange {
	valid_from: string | null;
	valid_from_precision: Precision;
	valid_to: string | null;
	valid_to_precision: Precision;
}

export type TimelineSection = 'lifespan' | 'conditions' | 'shapes' | 'addresses' | 'names' | 'relations' | 'spaces' | 'facts';

/** In page order, with what each section's fixes do. */
export const TIMELINE_SECTIONS: Record<TimelineSection, { title: string; why: string }> = {
	lifespan: { title: 'Lifespan', why: 'When it stood. Everything else is fitted to this.' },
	conditions: { title: 'Conditions', why: 'One continuous history from start to end: in use until something else is recorded, no overlaps or gaps, and how it ended.' },
	shapes: { title: 'Shapes', why: 'A single footprint, point or line covers the whole lifespan; redrawn ones follow each other.' },
	addresses: { title: 'Addresses', why: 'A single address covers the lifespan; several are kept within it.' },
	names: { title: 'Names', why: 'Official names follow each other; dated names stay within the lifespan.' },
	relations: { title: 'Relations', why: 'Tenants and occupants end when the place stops being in use; links stay within both sides’ lifespans; design and construction end when it’s built.' },
	spaces: { title: 'Spaces', why: 'Storefronts, suites and halls end with their building.' },
	facts: { title: 'Facts', why: 'Dated facts stay within the lifespan.' }
};

export const sectionTitle = (s: string) => TIMELINE_SECTIONS[s as TimelineSection]?.title ?? s;

const range = (r?: FixRange) => (r ? formatRange(r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision) || 'undated' : '');
const date = (d: string | null | undefined, p: Precision | undefined) => (d ? formatFuzzy(d, p ?? 'year') : 'open');
const from = (r?: FixRange) => date(r?.valid_from, r?.valid_from_precision);
const to = (r?: FixRange) => date(r?.valid_to, r?.valid_to_precision);

const WHY: Record<string, string> = {
	start: 'starts with the lifespan',
	end: 'ends with the lifespan',
	open: 'runs on, as it still stands',
	overlap: 'ends where the next one starts',
	gap: 'runs on until the next one'
};

/** One line saying what an item does. */
export function describeFix(f: TimelineFix): string {
	const a = f.after;
	const b = f.before;
	const q = (s?: string | null) => `“${s ?? ''}”`;
	switch (f.rule) {
		// lifespan
		case 'end_lifespan':
			return `End the lifespan in ${to(a)}, when it's recorded as ${q(f.label)}.`;
		case 'start_lifespan':
			return `Start the lifespan in ${from(a)}, from the earliest dated ${f.label}. That's when it was first recorded, not necessarily built.`;
		case 'gone_mismatch':
			return `End the lifespan in ${to(a)}, when ${q(f.label)} is recorded, instead of ${to(b)}.`;
		// conditions
		case 'seed_active':
			return `Add ${q(f.label)} for ${range(a)}: no condition is recorded.`;
		case 'fill_active':
			return `Add ${q(f.label)} for ${range(a)}, before ${q(f.next)}.`;
		case 'extend_back':
			return `Start ${q(f.label)} with the lifespan in ${from(a)}.`;
		case 'date_at_start':
			return `Date ${q(f.label)} from the start of the lifespan, ${from(a)}.`;
		case 'date_at_end':
			return `Date ${q(f.label)} at the end of the lifespan, ${from(a)}.`;
		case 'merge_duplicate':
			return f.op === 'delete' ? `Remove the repeated ${q(f.label)} (${range(b)}).` : `${q(f.label)} runs on to ${to(a)}, covering its repeat.`;
		case 'clamp_start':
			return `Start ${q(f.label)} with the lifespan in ${from(a)}.`;
		case 'close_overlap':
			return `End ${q(f.label)} in ${to(a)}, when ${q(f.next)} begins.`;
		case 'close_gap':
			return `Carry ${q(f.label)} on to ${to(a)}, when ${q(f.next)} begins.`;
		case 'close_at_end':
			return `End ${q(f.label)} in ${to(a)}, with the lifespan.`;
		case 'add_gone':
			return `Add ${q(f.label)} from ${from(a)}, when the lifespan ends.`;
		case 'after_end':
			return `Remove ${q(f.label)} (${range(b)}): it starts after the lifespan ends.`;
		case 'extend_open':
			return `Keep ${q(f.label)} running: it ends in ${to(b)} but nothing recorded follows.`;
		// shapes, addresses, names, relations, spaces, facts
		case 'end_with_use':
			return `${f.label}: ends in ${to(a)}, when it's recorded as ${q(f.use)}.`;
		case 'end_at_construction':
			return `${f.label}: ends with construction, in ${to(a)}.`;
		case 'start_with_place':
			return `${f.label}: starts in ${from(a)}, when the place does.`;
		case 'fit_shape':
		case 'fit_address':
		case 'fit_name':
		case 'fit_relation':
		case 'fit_space':
		case 'fit_fact': {
			const reasons = (f.why ?? []).map((w) => WHY[w]).filter(Boolean);
			const what = f.rule === 'fit_shape' ? capital(f.label ?? 'shape') : f.label ?? '';
			return `${what}: ${reasons.length ? reasons.join(', ') : 'fitted to the lifespan'}.`;
		}
		// notes
		case 'undated_conditions':
			return `${f.label} conditions have no date, so their order is unknown. Date them by hand.`;
		case 'undated_condition':
			return `${q(f.label)} has no date. Add the year it happened by hand.`;
		case 'concurrent':
			return `Several ${f.label === 'area' ? 'footprints' : `${f.label ?? ''} shapes`} start on the same date (wings drawn separately, or a duplicate?), so they weren't chained.`;
		case 'rebuilt':
			return `Recorded as ${q(f.label)} in ${from(b)}, then ${q(f.next)} in ${to(b)}: two buildings in one page. Duplicate the page, then remove the later facts here and the earlier ones from the copy.`;
		case 'outside':
			return `${q(f.label)} (${range(b)}) lies outside the lifespan. Check its dates or the lifespan.`;
		default:
			return f.label ? `${f.label}: ${f.rule}` : f.rule;
	}
}

const capital = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** "1920 – → 1920 – 1970" for items that change a range. */
export function fixChange(f: TimelineFix): string | null {
	if (f.op !== 'update' || !f.before || !f.after) return null;
	const b = range(f.before);
	const a = range(f.after);
	return b === a ? null : `${b} → ${a}`;
}
