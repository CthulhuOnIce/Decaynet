import { browser } from '$app/environment';

export type SavedView = { center: [number, number]; zoom: number };

const KEY = 'decaynet:view';
const YEAR_KEY = 'decaynet:year';

/** Last map camera, so switching between map, workbench, import etc. doesn't lose your place. */
export function loadView(): SavedView | undefined {
	if (!browser) return undefined;
	try {
		const v = JSON.parse(sessionStorage.getItem(KEY) ?? 'null');
		if (v && Array.isArray(v.center) && v.center.length === 2 && [...v.center, v.zoom].every(Number.isFinite)) return v;
	} catch {
		/* storage unavailable or corrupt */
	}
	return undefined;
}

export function saveView(v: SavedView) {
	if (!browser) return;
	try {
		sessionStorage.setItem(KEY, JSON.stringify({ center: v.center, zoom: v.zoom }));
	} catch {
		/* ignore */
	}
}

export function loadYear(): number | undefined {
	if (!browser) return undefined;
	const n = Number(sessionStorage.getItem(YEAR_KEY));
	return Number.isFinite(n) && n ? n : undefined;
}

export function saveYear(y: number) {
	if (!browser) return;
	try {
		sessionStorage.setItem(YEAR_KEY, String(y));
	} catch {
		/* ignore */
	}
}
