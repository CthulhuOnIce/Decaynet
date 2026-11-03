import { readGeometry } from '$lib/geojson';
import { NEW_SOURCE } from '$lib/sources';
import { parseFuzzyDate } from '$lib/time';
import { CONFIDENCES, PRECISIONS, type Confidence, type Precision } from '$lib/types';

export class FormError extends Error {}

/**
 * The shape a form sends: GeoJSON pasted into "<name>_text" wins over the shape drawn on the map
 * ("<name>"). Any GeoJSON form works (geometry, Feature, FeatureCollection). Null when neither is given.
 */
export function geometryFromForm(fd: FormData, name = 'geojson'): GeoJSON.Geometry | null {
	const text = str(fd, `${name}_text`) ?? str(fd, name);
	if (!text) return null;
	const r = readGeometry(text);
	if ('error' in r) throw new FormError(`The pasted shape can't be used: ${r.error}`);
	return r.geometry;
}

export const str = (fd: FormData, key: string): string | null => {
	const v = fd.get(key);
	if (typeof v !== 'string') return null;
	const t = v.trim();
	return t === '' ? null : t;
};

export const required = (fd: FormData, key: string, label = key): string => {
	const v = str(fd, key);
	if (!v) throw new FormError(`${label} is required.`);
	return v;
};

const asPrecision = (v: string | null): Precision | null =>
	v && (PRECISIONS as string[]).includes(v) ? (v as Precision) : null;

/**
 * Read a fuzzy date pair. A precision <select> next to the text box wins over
 * the precision inferred from the text ("1926" + decade → 1920s).
 */
export function fuzzyPair(fd: FormData, fromKey: string, toKey: string) {
	const from = parseFuzzyDate(str(fd, fromKey));
	const to = parseFuzzyDate(str(fd, toKey));
	const fromP = asPrecision(str(fd, `${fromKey}_precision`)) ?? from?.precision ?? 'year';
	const toP = asPrecision(str(fd, `${toKey}_precision`)) ?? to?.precision ?? 'year';
	if (from?.date && to?.date && to.date < from.date)
		throw new FormError('The end date is before the start date.');
	return {
		from: from?.date ?? null,
		fromPrecision: fromP,
		to: to?.date ?? null,
		toPrecision: toP,
		approximate: Boolean(from?.approximate || to?.approximate)
	};
}

function sourceId(fd: FormData): string | null {
	const id = str(fd, 'source_id');
	// resolveInlineSource() turns "new" into a real id before this runs
	if (id === NEW_SOURCE) throw new FormError('Creating a new source is not available here; pick an existing one.');
	return id;
}

/** Every component row's shared header, from <TemporalFields>. */
export function temporalFromForm(fd: FormData) {
	const pair = fuzzyPair(fd, 'valid_from', 'valid_to');
	let confidence = (str(fd, 'confidence') ?? 'probable') as Confidence;
	if (!CONFIDENCES.includes(confidence)) confidence = 'probable';
	if (pair.approximate && confidence === 'probable') confidence = 'approximate';
	return {
		valid_from: pair.from,
		valid_from_precision: pair.fromPrecision,
		valid_to: pair.to,
		valid_to_precision: pair.toPrecision,
		confidence,
		source_id: sourceId(fd),
		source_detail: str(fd, 'source_detail'),
		note: str(fd, 'note')
	};
}

export { slugifyClient as slugify } from '$lib/slug';

/** Turn a PostgREST / Postgres error into something a contributor can act on. */
export function dbMessage(error: { message: string; code?: string } | null): string {
	if (!error) return 'Unknown error';
	if (error.code === '42501' || /row-level security/i.test(error.message))
		return error.message.includes('row-level security')
			? 'You need to be signed in as a contributor to do that.'
			: error.message;
	if (error.code === '23505') return 'That already exists (duplicate slug or key).';
	if (error.code === '23503') return 'That refers to something that does not exist.';
	if (error.code === '23514') return `Value rejected by a check constraint: ${error.message}`;
	return error.message;
}
