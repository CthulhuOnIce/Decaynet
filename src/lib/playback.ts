/*
 * How the year slider's ▶ plays history: kept in this browser (a viewer's own preference).
 */
import { browser } from '$app/environment';

export interface Playback {
	/** how long each year stays on screen, in ms */
	hold: number;
	/** years per step */
	step: number;
	direction: 'forward' | 'back';
	/** play between these years (null: the slider's ends) */
	from: number | null;
	to: number | null;
	loop: boolean;
	/** stay longer on years with things happening (the amber ticks) */
	linger: boolean;
	/** skip years with nothing recorded */
	skipQuiet: boolean;
	/** don't move on until the map has drawn the year */
	waitForMap: boolean;
}

export const PLAYBACK_DEFAULTS: Playback = {
	hold: 500,
	step: 1,
	direction: 'forward',
	from: null,
	to: null,
	loop: false,
	linger: false,
	skipQuiet: false,
	waitForMap: true
};

export const HOLD_PRESETS = [
	{ label: 'Fast', ms: 250 },
	{ label: 'Normal', ms: 500 },
	{ label: 'Slow', ms: 1200 },
	{ label: 'Very slow', ms: 3000 }
];
export const STEPS = [1, 2, 5, 10];
/** how much longer a year with things happening stays */
export const LINGER_FACTOR = 3;

const KEY = 'decaynet:playback';
const clampYear = (v: unknown) => (typeof v === 'number' && Number.isInteger(v) && v > 0 && v < 10000 ? v : null);

export function loadPlayback(): Playback {
	if (!browser) return { ...PLAYBACK_DEFAULTS };
	try {
		const v = JSON.parse(localStorage.getItem(KEY) ?? 'null') as Partial<Playback> | null;
		if (!v || typeof v !== 'object') return { ...PLAYBACK_DEFAULTS };
		return {
			hold: typeof v.hold === 'number' && v.hold >= 50 && v.hold <= 10000 ? v.hold : PLAYBACK_DEFAULTS.hold,
			step: STEPS.includes(v.step as number) ? (v.step as number) : 1,
			direction: v.direction === 'back' ? 'back' : 'forward',
			from: clampYear(v.from),
			to: clampYear(v.to),
			loop: !!v.loop,
			linger: !!v.linger,
			skipQuiet: !!v.skipQuiet,
			waitForMap: v.waitForMap !== false
		};
	} catch {
		return { ...PLAYBACK_DEFAULTS };
	}
}

export function savePlayback(p: Playback) {
	if (!browser) return;
	try {
		localStorage.setItem(KEY, JSON.stringify(p));
	} catch {
		/* storage unavailable: the settings last for this visit */
	}
}

export const holdLabel = (ms: number) => (ms < 1000 ? `${(ms / 1000).toFixed(2).replace(/0$/, '')} s` : `${(ms / 1000).toFixed(1).replace(/\.0$/, '')} s`);
