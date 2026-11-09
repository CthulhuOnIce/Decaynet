/**
 * Where two sets of street lines cross (or stop just short of each other), for the
 * workbench's "pin an intersection". Pure; works in local metres about a centre.
 */

export type LL = [number, number];

/** "Broadway & 5th Ave", "Broadway and Fifth", "corner of Broadway at 5th", "Broadway / 5th" → the two streets. */
export function splitCrossing(q: string): [string, string] | null {
  const parts = q
    .replace(/^\s*(the\s+)?(corner|intersection|crossing)\s+of\s+/i, "")
    .split(/\s*(?:&|\+|\/|@|\||;|,|\band\b|\bat\b|\bx\b)\s*/i)
    .map((s) => s.trim())
    .filter(Boolean);
  return parts.length >= 2 ? [parts[0], parts[1]] : null;
}

export type CrossingHit = {
  lon: number;
  lat: number;
  /** the streets, as the wiki or OpenStreetMap names them */
  a: string;
  b: string;
  /** pages, when the wiki has the streets */
  a_slug?: string;
  b_slug?: string;
  /** metres between the streets' ends, when they stop just short of each other */
  gap_m: number;
  /** wiki: from the streets mapped here (in the sheet's year, if `then`); osm: today's streets */
  from: "wiki" | "osm";
  then?: boolean;
};

export type Crossing = { lon: number; lat: number; gap_m: number };

const R = 6371008.8;

/** Lines from GeoJSON geometry: LineString / MultiLineString (anything else is ignored). */
export function linesOf(g: GeoJSON.Geometry | null | undefined): LL[][] {
  if (!g) return [];
  if (g.type === "LineString") return [g.coordinates as LL[]];
  if (g.type === "MultiLineString") return g.coordinates as LL[][];
  if (g.type === "GeometryCollection") return g.geometries.flatMap(linesOf);
  return [];
}

type P = [number, number];

/**
 * Every place a line of A meets a line of B: where they cross, or (when they don't) the middle of
 * the shortest gap between them if it's at most maxGap metres. Crossings within 15 m of each other
 * are one (two ways that meet at a node). Nearest `near` first.
 */
export function crossings(
  a: LL[][],
  b: LL[][],
  near: LL | null = null,
  maxGap = 25,
): Crossing[] {
  const all = [...a, ...b].flat();
  if (!all.length) return [];
  const lat0 =
    (near ? near[1] : all.reduce((s, p) => s + p[1], 0) / all.length) *
    (Math.PI / 180);
  const lon0 = near ? near[0] : all.reduce((s, p) => s + p[0], 0) / all.length;
  const kx = (Math.PI / 180) * R * Math.cos(lat0);
  const ky = (Math.PI / 180) * R;
  const fwd = ([x, y]: LL): P => [
    (x - lon0) * kx,
    (y - lat0 * (180 / Math.PI)) * ky,
  ];
  const back = ([x, y]: P): LL => [
    x / kx + lon0,
    y / ky + lat0 * (180 / Math.PI),
  ];
  const A = a.map((l) => l.map(fwd));
  const B = b.map((l) => l.map(fwd));
  const box = (l: P[]) => {
    let x0 = Infinity,
      y0 = Infinity,
      x1 = -Infinity,
      y1 = -Infinity;
    for (const [x, y] of l) {
      x0 = Math.min(x0, x);
      y0 = Math.min(y0, y);
      x1 = Math.max(x1, x);
      y1 = Math.max(y1, y);
    }
    return { x0, y0, x1, y1 };
  };
  const near2 = (
    p: { x0: number; y0: number; x1: number; y1: number },
    q: typeof p,
  ) =>
    p.x0 - maxGap <= q.x1 &&
    q.x0 - maxGap <= p.x1 &&
    p.y0 - maxGap <= q.y1 &&
    q.y0 - maxGap <= p.y1;

  const found: { p: P; gap: number }[] = [];
  const boxesB = B.map(box);
  for (const la of A) {
    const ba = box(la);
    for (let j = 0; j < B.length; j++) {
      if (!near2(ba, boxesB[j])) continue;
      const lb = B[j];
      let crossed = false;
      let best: { p: P; gap: number } | null = null;
      for (let i = 0; i + 1 < la.length; i++) {
        for (let k = 0; k + 1 < lb.length; k++) {
          const x = segCross(la[i], la[i + 1], lb[k], lb[k + 1]);
          if (x) {
            found.push({ p: x, gap: 0 });
            crossed = true;
          } else if (!crossed) {
            const g = segGap(la[i], la[i + 1], lb[k], lb[k + 1]);
            if (g.d <= maxGap && (!best || g.d < best.gap))
              best = { p: g.mid, gap: g.d };
          }
        }
      }
      if (!crossed && best) found.push(best);
    }
  }
  // one per spot: a crossing beats a near miss beside it
  found.sort((p, q) => p.gap - q.gap);
  const kept: { p: P; gap: number }[] = [];
  for (const f of found)
    if (!kept.some((k) => Math.hypot(k.p[0] - f.p[0], k.p[1] - f.p[1]) < 15))
      kept.push(f);
  const c = near ? fwd(near) : null;
  if (c)
    kept.sort(
      (p, q) =>
        Math.hypot(p.p[0] - c[0], p.p[1] - c[1]) -
        Math.hypot(q.p[0] - c[0], q.p[1] - c[1]),
    );
  return kept.map((k) => {
    const [lon, lat] = back(k.p);
    return {
      lon: +lon.toFixed(7),
      lat: +lat.toFixed(7),
      gap_m: Math.round(k.gap * 10) / 10,
    };
  });
}

function segCross(p: P, p2: P, q: P, q2: P): P | null {
  const r: P = [p2[0] - p[0], p2[1] - p[1]];
  const s: P = [q2[0] - q[0], q2[1] - q[1]];
  const d = r[0] * s[1] - r[1] * s[0];
  if (Math.abs(d) < 1e-9) return null;
  const t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / d;
  const u = ((q[0] - p[0]) * r[1] - (q[1] - p[1]) * r[0]) / d;
  if (t < -1e-9 || t > 1 + 1e-9 || u < -1e-9 || u > 1 + 1e-9) return null;
  return [p[0] + t * r[0], p[1] + t * r[1]];
}

function closest(p: P, a: P, b: P): P {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const l2 = dx * dx + dy * dy;
  const t = l2
    ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2))
    : 0;
  return [a[0] + t * dx, a[1] + t * dy];
}

/** The shortest gap between two segments that don't cross: its length and middle. */
function segGap(p: P, p2: P, q: P, q2: P): { d: number; mid: P } {
  let best = { d: Infinity, mid: p };
  for (const [x, a, b] of [
    [p, q, q2],
    [p2, q, q2],
    [q, p, p2],
    [q2, p, p2],
  ] as [P, P, P][]) {
    const c = closest(x, a, b);
    const d = Math.hypot(c[0] - x[0], c[1] - x[1]);
    if (d < best.d) best = { d, mid: [(c[0] + x[0]) / 2, (c[1] + x[1]) / 2] };
  }
  return best;
}
