/**
 * Fit a scanned image onto the map from matched control points ("pins").
 *
 * Each pair links a pixel on the image to a point on the map. Points are
 * fitted in Web Mercator space (the space MapLibre draws image sources in),
 * by least squares, so extra pins average out small clicking errors.
 *
 * - 2 pins: similarity (move, rotate, uniform scale)
 * - 3+ pins: affine (also allows stretch and skew, e.g. a scan that isn't square)
 *
 * MapLibre renders an image source as two triangles, so only transforms that
 * map the image rectangle to a parallelogram (similarity / affine) render
 * without a seam; a full perspective fit is deliberately not offered.
 */

export type XY = [number, number];
export type FitKind = 'similarity' | 'affine';
/** x' = a·x + b·y + c ;  y' = d·x + e·y + f */
export type Affine = [number, number, number, number, number, number];

export interface Fit {
	kind: FitKind;
	m: Affine;
}

export const minPins = (kind: FitKind) => (kind === 'similarity' ? 2 : 3);

/** Web Mercator, normalised to 0..1 like MapLibre's MercatorCoordinate (y grows southwards, like image rows). */
export function toMerc([lng, lat]: XY): XY {
	const s = Math.sin((Math.max(-85.0511, Math.min(85.0511, lat)) * Math.PI) / 180);
	return [(lng + 180) / 360, 0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)];
}

export function fromMerc([x, y]: XY): XY {
	const n = Math.PI - 2 * Math.PI * y;
	return [x * 360 - 180, (180 / Math.PI) * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)))];
}

export const apply = (m: Affine, [x, y]: XY): XY => [m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5]];

/** Centre a point set and scale it to unit RMS distance, for numerical stability. */
function normaliser(pts: XY[]) {
	const cx = pts.reduce((s, p) => s + p[0], 0) / pts.length;
	const cy = pts.reduce((s, p) => s + p[1], 0) / pts.length;
	const r = Math.sqrt(pts.reduce((s, p) => s + (p[0] - cx) ** 2 + (p[1] - cy) ** 2, 0) / pts.length) || 1;
	return { cx, cy, r, fwd: ([x, y]: XY): XY => [(x - cx) / r, (y - cy) / r] };
}

/** Solve the least-squares problem A·x ≈ b via the normal equations. */
function lstsq(A: number[][], b: number[]): number[] | null {
	const n = A[0].length;
	const M = Array.from({ length: n }, (_, i) => {
		const row = Array.from({ length: n }, (_, j) => A.reduce((s, r) => s + r[i] * r[j], 0));
		row.push(A.reduce((s, r, k) => s + r[i] * b[k], 0));
		return row;
	});
	for (let c = 0; c < n; c++) {
		let p = c;
		for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
		if (Math.abs(M[p][c]) < 1e-12) return null;
		[M[c], M[p]] = [M[p], M[c]];
		for (let r = 0; r < n; r++) {
			if (r === c) continue;
			const f = M[r][c] / M[c][c];
			for (let k = c; k <= n; k++) M[r][k] -= f * M[c][k];
		}
	}
	return M.map((row, i) => row[n] / row[i]);
}

/** Fit image pixels → Mercator. Returns null when there are too few or degenerate pins. */
export function fit(img: XY[], merc: XY[], kind: FitKind): Fit | null {
	if (img.length !== merc.length || img.length < minPins(kind)) return null;
	const ni = normaliser(img);
	const nm = normaliser(merc);
	const P = img.map(ni.fwd);
	const Q = merc.map(nm.fwd);

	let local: Affine;
	if (kind === 'similarity') {
		// x' = a x − b y + tx ; y' = b x + a y + ty
		const A: number[][] = [];
		const B: number[] = [];
		P.forEach(([x, y], i) => {
			A.push([x, -y, 1, 0]);
			B.push(Q[i][0]);
			A.push([y, x, 0, 1]);
			B.push(Q[i][1]);
		});
		const s = lstsq(A, B);
		if (!s) return null;
		local = [s[0], -s[1], s[2], s[1], s[0], s[3]];
	} else {
		const A = P.map(([x, y]) => [x, y, 1]);
		const sx = lstsq(A, Q.map((q) => q[0]));
		const sy = lstsq(A, Q.map((q) => q[1]));
		if (!sx || !sy) return null;
		local = [sx[0], sx[1], sx[2], sy[0], sy[1], sy[2]];
	}

	// Undo the normalisation: merc = nm.r · local(ni(img)) + nm.c
	const [a, b, c, d, e, f] = local;
	const k = nm.r / ni.r;
	const m: Affine = [
		a * k,
		b * k,
		nm.r * (c - (a * ni.cx + b * ni.cy) / ni.r) + nm.cx,
		d * k,
		e * k,
		nm.r * (f - (d * ni.cx + e * ni.cy) / ni.r) + nm.cy
	];
	if (!m.every(Number.isFinite) || Math.abs(m[0] * m[4] - m[1] * m[3]) < 1e-24) return null;
	return { kind, m };
}

/** The image's four corners (top-left, clockwise) as lng/lat, ready for an ImageSource. */
export function cornersFor(f: Fit, width: number, height: number): [XY, XY, XY, XY] {
	const box: XY[] = [[0, 0], [width, 0], [width, height], [0, height]];
	return box.map((p) => fromMerc(apply(f.m, p))) as [XY, XY, XY, XY];
}

/** Ground distance in metres between two lng/lat points. */
export function metres([lng1, lat1]: XY, [lng2, lat2]: XY): number {
	const R = 6371008.8;
	const r = Math.PI / 180;
	const h = Math.sin(((lat2 - lat1) * r) / 2) ** 2 + Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin(((lng2 - lng1) * r) / 2) ** 2;
	return 2 * R * Math.asin(Math.sqrt(h));
}
