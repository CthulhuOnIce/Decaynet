/**
 * Aligning a scan by its streets: a street drawn on the scan and the same street drawn on the
 * map are lines (centrelines, any two points along them), not matching points. The scan moves,
 * turns and scales uniformly (no stretch), in Web Mercator like the pin fit.
 *
 * What the streets settle:
 * - 1 street: the turn, and which line the sheet sits on. It can still slide along the street
 *   and scale.
 * - 2 parallel streets: also the scale (the gap between them). It can still slide along them.
 * - 2 crossing streets: everything but the scale (the crossing pins the position).
 * - 3 or more (not all parallel, not all through one point): everything, by least squares.
 *
 * Whatever the streets leave free stays where it was (the closest placement to the current one),
 * and `free` says what that is, for the slide and scale handles.
 */
import { apply, type Affine, type XY } from './georef';

/** merc = s·R(th)·pixel + t */
export interface Pose {
	s: number;
	th: number;
	tx: number;
	ty: number;
}

export interface StreetPair {
	/** two pixels along the street on the scan */
	scan: [XY, XY];
	/** two Web Mercator points along the same street on the map */
	merc: [XY, XY];
}

export interface StreetFit {
	pose: Pose;
	/** what the streets leave to you */
	free: 'none' | 'slide' | 'scale' | 'slide+scale';
	/** the direction it can slide in (Mercator, unit) */
	slide: XY | null;
	/** the point it scales about (Mercator) when only the scale is free; null when you pick it */
	anchor: XY | null;
	/** how far each street's scan line lands from its map line, in Mercator units (for metres, see residualMetres) */
	residuals: number[];
	/** how much the streets disagree about the turn, in degrees (the biggest difference from the average) */
	turnSpread: number;
}

export const poseToAffine = ({ s, th, tx, ty }: Pose): Affine => [s * Math.cos(th), -s * Math.sin(th), tx, s * Math.sin(th), s * Math.cos(th), ty];

/** The pose of an affine fit's closest similarity (its rotation and average scale). */
export function poseFromAffine(m: Affine): Pose {
	// the similarity part of [a b; d e]: ((a+e)/2, (d-b)/2)
	const c = (m[0] + m[4]) / 2;
	const sn = (m[3] - m[1]) / 2;
	return { s: Math.hypot(c, sn), th: Math.atan2(sn, c), tx: m[2], ty: m[5] };
}

const sub = (a: XY, b: XY): XY => [a[0] - b[0], a[1] - b[1]];
const dot = (a: XY, b: XY) => a[0] * b[0] + a[1] * b[1];
const norm = (a: XY): XY => {
	const l = Math.hypot(a[0], a[1]) || 1;
	return [a[0] / l, a[1] / l];
};
const rot = (th: number, [x, y]: XY): XY => [Math.cos(th) * x - Math.sin(th) * y, Math.sin(th) * x + Math.cos(th) * y];
/** angle difference folded into (-π/2, π/2]: lines have no direction */
const fold = (a: number) => {
	let x = a % Math.PI;
	if (x <= -Math.PI / 2) x += Math.PI;
	if (x > Math.PI / 2) x -= Math.PI;
	return x;
};

/** Eigen-decomposition of a symmetric 3×3 matrix (Jacobi rotations). */
function eig3(A: number[][]): { values: number[]; vectors: number[][] } {
	const a = A.map((r) => [...r]);
	const v = [
		[1, 0, 0],
		[0, 1, 0],
		[0, 0, 1]
	];
	for (let sweep = 0; sweep < 50; sweep++) {
		let off = 0;
		for (let p = 0; p < 3; p++) for (let q = p + 1; q < 3; q++) off += a[p][q] ** 2;
		if (off < 1e-30) break;
		for (let p = 0; p < 3; p++)
			for (let q = p + 1; q < 3; q++) {
				if (Math.abs(a[p][q]) < 1e-300) continue;
				const theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
				const t = Math.sign(theta || 1) / (Math.abs(theta) + Math.sqrt(theta * theta + 1));
				const c = 1 / Math.sqrt(t * t + 1);
				const s = t * c;
				for (let k = 0; k < 3; k++) {
					const akp = a[k][p];
					const akq = a[k][q];
					a[k][p] = c * akp - s * akq;
					a[k][q] = s * akp + c * akq;
				}
				for (let k = 0; k < 3; k++) {
					const apk = a[p][k];
					const aqk = a[q][k];
					a[p][k] = c * apk - s * aqk;
					a[q][k] = s * apk + c * aqk;
				}
				for (let k = 0; k < 3; k++) {
					const vkp = v[k][p];
					const vkq = v[k][q];
					v[k][p] = c * vkp - s * vkq;
					v[k][q] = s * vkp + c * vkq;
				}
			}
	}
	return { values: [a[0][0], a[1][1], a[2][2]], vectors: [0, 1, 2].map((i) => [v[0][i], v[1][i], v[2][i]]) };
}

/**
 * Fit the streets, keeping whatever they leave free as close as possible to `prior` (where the
 * sheet is now). `size` is the scan's width and height in pixels.
 */
export function fitStreets(pairs: StreetPair[], prior: Pose, size: { width: number; height: number }): StreetFit {
	const ok = pairs.filter((p) => Math.hypot(...sub(p.scan[1], p.scan[0])) > 1e-9 && Math.hypot(...sub(p.merc[1], p.merc[0])) > 1e-12);
	if (!ok.length) return { pose: prior, free: 'slide+scale', slide: null, anchor: null, residuals: [], turnSpread: 0 };

	// 1. the turn: each street's angle on the map minus on the scan, averaged as lines (doubled
	//    angles), weighted by how long they're drawn; of the two ways round, the one nearer now
	const diffs = ok.map((p) => {
		const ds = sub(p.scan[1], p.scan[0]);
		const dm = sub(p.merc[1], p.merc[0]);
		return { d: Math.atan2(dm[1], dm[0]) - Math.atan2(ds[1], ds[0]), w: Math.hypot(...ds) };
	});
	const sx = diffs.reduce((s, x) => s + x.w * Math.sin(2 * x.d), 0);
	const cx = diffs.reduce((s, x) => s + x.w * Math.cos(2 * x.d), 0);
	const avg = Math.atan2(sx, cx) / 2;
	const away = (x: number) => Math.abs(Math.atan2(Math.sin(x - prior.th), Math.cos(x - prior.th)));
	const th = away(avg) <= away(avg + Math.PI) ? avg : avg + Math.PI;
	const turnSpread = (Math.max(...diffs.map((x) => Math.abs(fold(x.d - th)))) * 180) / Math.PI;

	// 2. with the turn fixed, each street is one linear equation in (S, tx, ty), S = s·L:
	//    the scan street's midpoint, placed, lies on the map street
	const L = Math.hypot(size.width, size.height) || 1;
	// streets within 2° of parallel don't settle the scale (their crossing is far off and wobbles
	// with every click): they're taken as exactly parallel, along their average direction
	const dirs = ok.map((p) => Math.atan2(p.merc[1][1] - p.merc[0][1], p.merc[1][0] - p.merc[0][0]));
	const mean = Math.atan2(dirs.reduce((s, d) => s + Math.sin(2 * d), 0), dirs.reduce((s, d) => s + Math.cos(2 * d), 0)) / 2;
	const parallel = ok.length > 1 && dirs.every((d) => Math.abs(fold(d - mean)) < (2 * Math.PI) / 180);
	const rows = ok.map((p) => {
		const dm = parallel ? ([Math.cos(mean), Math.sin(mean)] as XY) : norm(sub(p.merc[1], p.merc[0]));
		const n: XY = [-dm[1], dm[0]];
		const mid: XY = [(p.scan[0][0] + p.scan[1][0]) / 2, (p.scan[0][1] + p.scan[1][1]) / 2];
		const ra = rot(th, mid);
		return { a: [dot(n, ra) / L, n[0], n[1]], b: dot(n, p.merc[0]) };
	});
	const x0 = [prior.s * L, prior.tx, prior.ty];
	// min-norm correction from the prior: x = x0 + A⁺(b − A·x0)
	const M = [0, 1, 2].map((i) => [0, 1, 2].map((j) => rows.reduce((s, r) => s + r.a[i] * r.a[j], 0)));
	const { values, vectors } = eig3(M);
	const top = Math.max(...values.map(Math.abs), 1e-30);
	const kept = [0, 1, 2].filter((i) => values[i] > top * 1e-9);
	const resid = rows.map((r) => r.b - r.a.reduce((s, v, i) => s + v * x0[i], 0));
	const atr = [0, 1, 2].map((i) => rows.reduce((s, r, k) => s + r.a[i] * resid[k], 0));
	const x = [...x0];
	for (const i of kept) {
		const v = vectors[i];
		const c = (v[0] * atr[0] + v[1] * atr[1] + v[2] * atr[2]) / values[i];
		for (let k = 0; k < 3; k++) x[k] += c * v[k];
	}
	const pose: Pose = { s: Math.max(x[0] / L, 1e-30), th, tx: x[1], ty: x[2] };

	// 3. what's left free: the null space
	const nulls = [0, 1, 2].filter((i) => !kept.includes(i)).map((i) => vectors[i]);
	let free: StreetFit['free'] = 'none';
	let slide: XY | null = null;
	let anchor: XY | null = null;
	if (nulls.length >= 2) {
		free = 'slide+scale';
		slide = parallel ? [Math.cos(mean), Math.sin(mean)] : norm(sub(ok[0].merc[1], ok[0].merc[0]));
	} else if (nulls.length === 1) {
		const v = nulls[0];
		if (Math.abs(v[0]) < 0.05 * Math.hypot(v[1], v[2])) {
			free = 'slide';
			slide = norm([v[1], v[2]]);
		} else {
			// scaling about the point that stays put: t − S·v_t / v_S
			free = 'scale';
			anchor = [pose.tx - (x[0] * v[1]) / v[0], pose.ty - (x[0] * v[2]) / v[0]];
		}
	}
	const residuals = rows.map((r) => Math.abs(r.b - r.a.reduce((s, v, i) => s + v * x[i], 0)));
	return { pose, free, slide, anchor, residuals, turnSpread: ok.length > 1 ? turnSpread : 0 };
}

/** Slide the pose by a Mercator offset, kept to the direction the streets allow. */
export function slidePose(p: Pose, by: XY, dir: XY): Pose {
	const k = dot(by, dir);
	return { ...p, tx: p.tx + k * dir[0], ty: p.ty + k * dir[1] };
}

/** Scale the pose by k about a Mercator point (it stays where it is on the map). */
export function scalePose(p: Pose, k: number, about: XY): Pose {
	return { ...p, s: p.s * k, tx: about[0] + k * (p.tx - about[0]), ty: about[1] + k * (p.ty - about[1]) };
}

/** A pixel on the scan, placed on the map (Mercator). */
export const placed = (p: Pose, px: XY): XY => apply(poseToAffine(p), px);

/** The foot of the perpendicular from a point to a line (all Mercator). */
export function onLine(pt: XY, [a, b]: [XY, XY]): XY {
	const d = norm(sub(b, a));
	const k = dot(sub(pt, a), d);
	return [a[0] + k * d[0], a[1] + k * d[1]];
}
