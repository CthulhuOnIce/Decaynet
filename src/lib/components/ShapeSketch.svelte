<script lang="ts">
	/**
	 * A page's shapes drawn as a plain SVG outline: no map tiles, so it prints
	 * sharp and needs no network. Shapes in use at the chosen year are solid,
	 * earlier and later ones dashed. Includes a north arrow and a scale bar.
	 */
	let {
		features = [],
		width = 520,
		height = 300,
		label = 'Shapes'
	}: { features?: GeoJSON.Feature[]; width?: number; height?: number; label?: string } = $props();

	type Pos = [number, number];
	const parts = (g: GeoJSON.Geometry | null): { kind: 'area' | 'line' | 'point'; rings: Pos[][] }[] => {
		if (!g) return [];
		switch (g.type) {
			case 'Point':
				return [{ kind: 'point', rings: [[g.coordinates as Pos]] }];
			case 'MultiPoint':
				return g.coordinates.map((c) => ({ kind: 'point' as const, rings: [[c as Pos]] }));
			case 'LineString':
				return [{ kind: 'line', rings: [g.coordinates as Pos[]] }];
			case 'MultiLineString':
				return g.coordinates.map((c) => ({ kind: 'line' as const, rings: [c as Pos[]] }));
			case 'Polygon':
				return [{ kind: 'area', rings: g.coordinates as Pos[][] }];
			case 'MultiPolygon':
				return g.coordinates.map((c) => ({ kind: 'area' as const, rings: c as Pos[][] }));
			case 'GeometryCollection':
				return g.geometries.flatMap(parts);
		}
	};

	const shapes = $derived(
		features.flatMap((f) => parts(f.geometry).map((p) => ({ ...p, current: !!f.properties?.current, role: String(f.properties?.role ?? '') })))
	);
	const PAD = 24;
	const view = $derived.by(() => {
		const pts = shapes.flatMap((s) => s.rings.flat());
		if (!pts.length) return null;
		let [w, s, e, n] = [Infinity, Infinity, -Infinity, -Infinity];
		for (const [x, y] of pts) [w, s, e, n] = [Math.min(w, x), Math.min(s, y), Math.max(e, x), Math.max(n, y)];
		const lat = (s + n) / 2;
		const kx = Math.cos((lat * Math.PI) / 180); // equirectangular, true to scale near this latitude
		// at least ~80 m across, so a lone point or a small building isn't blown up to fill the box
		const minDeg = 80 / 111_320;
		const spanX = Math.max((e - w) * kx, minDeg);
		const spanY = Math.max(n - s, minDeg);
		const scale = Math.min((width - 2 * PAD) / spanX, (height - 2 * PAD) / spanY); // px per degree of latitude
		const cx = (w + e) / 2;
		const cy = (s + n) / 2;
		const xy = ([x, y]: Pos): Pos => [width / 2 + (x - cx) * kx * scale, height / 2 - (y - cy) * scale];
		// scale bar: a round length near a quarter of the width
		const mPerPx = 111_320 / scale;
		const target = (width / 4) * mPerPx;
		const step = [1, 2, 5].flatMap((m) => [1, 10, 100, 1000, 10000].map((p) => m * p)).filter((v) => v <= target).pop() ?? 1;
		return { xy, bar: { px: step / mPerPx, label: step >= 1000 ? `${step / 1000} km` : `${step} m` } };
	});
	const path = (rings: Pos[][], close: boolean) =>
		view ? rings.map((r) => r.map((p, i) => `${i ? 'L' : 'M'}${view.xy(p).map((v) => v.toFixed(1)).join(' ')}`).join(' ') + (close ? ' Z' : '')).join(' ') : '';
</script>

{#if view}
	<svg viewBox="0 0 {width} {height}" class="sketch" role="img" aria-label={label}>
		<rect x="0.5" y="0.5" width={width - 1} height={height - 1} class="frame" />
		<!-- older/later shapes first, the ones in use on top -->
		{#each [...shapes].sort((a, b) => Number(a.current) - Number(b.current)) as s, i (i)}
			{#if s.kind === 'point'}
				{@const [x, y] = view.xy(s.rings[0][0])}
				<circle cx={x} cy={y} r="5" class:current={s.current} class="pt" />
			{:else}
				<path d={path(s.rings, s.kind === 'area')} class={s.kind} class:current={s.current} fill-rule="evenodd" />
			{/if}
		{/each}
		<g class="north" transform="translate({width - 22} 26)">
			<path d="M0 -12 L6 6 L0 2 L-6 6 Z" />
			<text y="18" text-anchor="middle">N</text>
		</g>
		<g class="bar" transform="translate(14 {height - 14})">
			<path d="M0 -5 V0 H{view.bar.px} V-5" />
			<text x={view.bar.px / 2} y="-8" text-anchor="middle">{view.bar.label}</text>
		</g>
	</svg>
{/if}

<style>
	.sketch {
		width: 100%;
		height: auto;
		display: block;
		font-family: var(--sans);
	}
	.frame {
		fill: none;
		stroke: var(--line);
	}
	.area,
	.line {
		stroke: var(--muted);
		stroke-width: 1.5;
		stroke-dasharray: 4 3;
		vector-effect: non-scaling-stroke;
	}
	.area {
		fill: none;
	}
	.line {
		fill: none;
	}
	.area.current {
		fill: color-mix(in srgb, var(--rust) 18%, transparent);
		stroke: var(--rust);
		stroke-width: 2;
		stroke-dasharray: none;
	}
	.line.current {
		stroke: var(--rust);
		stroke-width: 3;
		stroke-dasharray: none;
	}
	.pt {
		fill: none;
		stroke: var(--muted);
		stroke-width: 1.5;
	}
	.pt.current {
		fill: var(--rust);
		stroke: var(--rust);
	}
	.north path {
		fill: var(--ink);
	}
	.north text,
	.bar text {
		font-size: 10px;
		fill: var(--ink-2);
	}
	.bar path {
		fill: none;
		stroke: var(--ink-2);
		stroke-width: 1.5;
	}
</style>
