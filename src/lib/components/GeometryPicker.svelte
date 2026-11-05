<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import { onDestroy, onMount, untrack } from 'svelte';
	import { page } from '$app/state';
	import type { GeoJSONSource, Map as MLMap } from 'maplibre-gl';
	import { FONT, baseStyle, boundsOf, mapView } from '$lib/map/style';
	import { loadView } from '$lib/mapMemory';
	import { readGeometry } from '$lib/geojson';

	type Mode = 'point' | 'line' | 'polygon';

	let {
		name = 'geojson',
		mode: initialMode = 'point',
		context = [],
		height = 360,
		snap = true,
		initial = null,
		each = null,
		pasteText = $bindable('')
	}: {
		name?: string;
		mode?: Mode;
		/** existing shapes drawn for reference */
		context?: GeoJSON.Feature[];
		height?: number;
		/** snap clicks to nearby vertices of the context shapes (shared walls, street corners) */
		snap?: boolean;
		/** a starting shape, e.g. a point carried over from a geocoded address */
		initial?: GeoJSON.Geometry | null;
		/** several pasted areas each become one of these (e.g. "space"), rather than one shape */
		each?: string | null;
		/** the pasted GeoJSON text (bind it to read the pasted areas) */
		pasteText?: string;
	} = $props();

	function pointsOf(g: GeoJSON.Geometry | null): [number, number][] {
		if (!g) return [];
		if (g.type === 'Point') return [g.coordinates as [number, number]];
		if (g.type === 'LineString') return g.coordinates as [number, number][];
		if (g.type === 'Polygon') return (g.coordinates[0] ?? []).slice(0, -1) as [number, number][];
		return [];
	}

	function contextVertices(): [number, number][] {
		const out: [number, number][] = [];
		const walk = (c: unknown): void => {
			if (Array.isArray(c) && typeof c[0] === 'number') out.push([c[0] as number, c[1] as number]);
			else if (Array.isArray(c)) c.forEach(walk);
		};
		for (const f of context) if (f.geometry && 'coordinates' in f.geometry) walk(f.geometry.coordinates);
		return out;
	}

	let mode = $state<Mode>('point');
	$effect.pre(() => {
		mode = initialMode;
	});
	let pts = $state<[number, number][]>(untrack(() => pointsOf(initial)));
	let el: HTMLDivElement;
	let map: MLMap | undefined;
	let ready = false;

	const geometry = $derived.by((): GeoJSON.Geometry | null => {
		if (mode === 'point') return pts.length ? { type: 'Point', coordinates: pts[pts.length - 1] } : null;
		if (mode === 'line') return pts.length >= 2 ? { type: 'LineString', coordinates: pts } : null;
		return pts.length >= 3 ? { type: 'Polygon', coordinates: [[...pts, pts[0]]] } : null;
	});
	const value = $derived(geometry ? JSON.stringify(geometry) : '');

	// ---- pasted GeoJSON: a simple shape is loaded onto the map to adjust; anything else (several
	// parts, holes) is kept as pasted and previewed. The server reads it the same way (readGeometry).
	let pasted = $state<GeoJSON.Geometry | null>(null);
	let pasteNote = $state<string | null>(null);
	let pasteError = $state<string | null>(null);
	function onPaste() {
		if (!pasteText.trim()) {
			// emptied: drop a kept paste and its note, but keep "loaded onto the map" (the box is
			// emptied on purpose then, and some browsers send another input event for it)
			if (pasted || pasteError) pasteNote = null;
			pasted = null;
			pasteError = null;
			return;
		}
		pasted = null;
		pasteNote = pasteError = null;
		const r = readGeometry(pasteText);
		if ('error' in r) return void (pasteError = r.error);
		const g = r.geometry;
		const editable = g.type === 'Point' || g.type === 'LineString' || (g.type === 'Polygon' && g.coordinates.length === 1);
		if (editable) {
			mode = g.type === 'Point' ? 'point' : g.type === 'LineString' ? 'line' : 'polygon';
			pts = pointsOf(g);
			pasteText = ''; // the map now holds it, and edits made there are what gets saved
			pasteNote = `Pasted ${g.type === 'Point' ? 'point' : g.type === 'LineString' ? 'line' : 'area'} is on the map; adjust it there if needed.`;
		} else {
			pts = []; // the pasted text is what's saved, so don't leave an older drawing beside it
			pasted = g;
			pasteNote =
				each && r.parts > 1 && g.type === 'MultiPolygon'
					? `${r.parts} areas pasted: each becomes its own ${each}. Clear this box to draw on the map instead.`
					: `${r.note ?? 'An area with holes, kept as pasted.'} Clear this box to draw on the map instead.`;
		}
		const b = boundsOf(g);
		if (b && map) map.fitBounds(b, { padding: 60, maxZoom: 18, duration: 300 });
	}
	/** multi-part shapes as separate features, so the Polygon/Point layer filters catch every part */
	const partsOf = (g: GeoJSON.Geometry): GeoJSON.Geometry[] =>
		g.type === 'MultiPolygon'
			? g.coordinates.map((c) => ({ type: 'Polygon', coordinates: c }))
			: g.type === 'MultiLineString'
				? g.coordinates.map((c) => ({ type: 'LineString', coordinates: c }))
				: g.type === 'MultiPoint'
					? g.coordinates.map((c) => ({ type: 'Point', coordinates: c }))
					: [g];

	function draw() {
		if (!map || !ready) return;
		const features: GeoJSON.Feature[] = pts.map((c) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: c }, properties: { vertex: true } }));
		if (geometry && geometry.type !== 'Point') features.push({ type: 'Feature', geometry, properties: {} });
		// several pasted areas that each become a page are numbered, to match them with their rows
		if (pasted) partsOf(pasted).forEach((g, i) => features.push({ type: 'Feature', geometry: g, properties: each ? { n: String(i + 1) } : {} }));
		(map.getSource('draft') as GeoJSONSource).setData({ type: 'FeatureCollection', features });
	}

	onMount(async () => {
		const maplibregl = (await import('maplibre-gl')).default;
		map = new maplibregl.Map({ container: el, style: baseStyle(page.data.settings), ...mapView(page.data.settings, 3), ...loadView(), attributionControl: { compact: true } });
		map.doubleClickZoom.disable();
		map.getCanvas().style.cursor = 'crosshair';
		map.on('load', () => {
			const m = map!;
			m.setPaintProperty('basemap', 'raster-opacity', 0.75);
			m.addSource('context', { type: 'geojson', data: { type: 'FeatureCollection', features: context } });
			m.addSource('draft', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			m.addLayer({ id: 'ctx-fill', type: 'fill', source: 'context', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#8fb3c9', 'fill-opacity': 0.12 } });
			m.addLayer({ id: 'ctx-line', type: 'line', source: 'context', filter: ['!=', ['geometry-type'], 'Point'], paint: { 'line-color': '#8fb3c9', 'line-width': 2, 'line-dasharray': [2, 2] } });
			m.addLayer({ id: 'ctx-pt', type: 'circle', source: 'context', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 6, 'circle-color': 'rgba(0,0,0,0)', 'circle-stroke-color': '#8fb3c9', 'circle-stroke-width': 2 } });
			m.addLayer({ id: 'draft-fill', type: 'fill', source: 'draft', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#c2562b', 'fill-opacity': 0.35 } });
			m.addLayer({ id: 'draft-line', type: 'line', source: 'draft', filter: ['!=', ['geometry-type'], 'Point'], paint: { 'line-color': '#e07a4f', 'line-width': 3 } });
			m.addLayer({ id: 'draft-pt', type: 'circle', source: 'draft', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 5, 'circle-color': '#f2c14e', 'circle-stroke-color': '#17130f', 'circle-stroke-width': 1.5 } });
			m.addLayer({
				id: 'draft-num',
				type: 'symbol',
				source: 'draft',
				filter: ['all', ['==', ['geometry-type'], 'Polygon'], ['has', 'n']],
				layout: { 'text-field': ['get', 'n'], 'text-font': FONT, 'text-size': 15, 'text-allow-overlap': true },
				paint: { 'text-color': '#fff', 'text-halo-color': '#17130f', 'text-halo-width': 2 }
			});
			const b = context.length ? boundsOf({ type: 'FeatureCollection', features: context }) : null;
			if (b) m.fitBounds(b, { padding: 60, maxZoom: 17, duration: 0 });
			else if (pts.length) m.jumpTo({ center: pts[0], zoom: Math.max(m.getZoom(), 16) });
			m.on('click', (e) => {
				let c: [number, number] = [+e.lngLat.lng.toFixed(7), +e.lngLat.lat.toFixed(7)];
				if (snap) {
					let best = 10; // px
					for (const v of [...contextVertices(), ...pts]) {
						const p = m.project(v);
						const d = Math.hypot(p.x - e.point.x, p.y - e.point.y);
						if (d < best) {
							best = d;
							c = v;
						}
					}
				}
				pts = mode === 'point' ? [c] : [...pts, c];
			});
			ready = true;
			draw();
		});
	});
	onDestroy(() => map?.remove());

	$effect(() => {
		void [geometry, pasted];
		draw();
	});
</script>

<div class="gp">
	<div class="row bar">
		{#each ['point', 'line', 'polygon'] as const as m (m)}
			<label class="radio"><input type="radio" bind:group={mode} value={m} onchange={() => (pts = [])} /> {m}</label>
		{/each}
		<span class="muted small">
			{mode === 'point' ? 'Click to place.' : `Click to add vertices (${pts.length}).`}
			{snap && context.length ? ' Snaps to nearby corners.' : ''}
		</span>
		<span class="spacer"></span>
		<button type="button" class="ghost" onclick={() => (pts = pts.slice(0, -1))} disabled={!pts.length}>Undo</button>
		<button type="button" class="ghost" onclick={() => (pts = [])} disabled={!pts.length}>Clear</button>
	</div>
	<div class="map" style:height="{height}px" bind:this={el}></div>
	<input type="hidden" {name} {value} />
	<details open={!!pasteText || !!pasteNote || !!pasteError}>
		<summary class="muted small">…or paste GeoJSON (a shape copied from the workbench, or any GeoJSON file's contents)</summary>
		<textarea
			name="{name}_text"
			rows="4"
			bind:value={pasteText}
			oninput={onPaste}
			class:bad={!!pasteError}
			placeholder={'{"type":"Polygon","coordinates":[[[-87.33,41.60],…]]}  or a Feature / FeatureCollection'}
		></textarea>
		{#if pasteError}<p class="small paste-error">{pasteError}</p>{:else if pasteNote}<p class="small paste-ok">{pasteNote}</p>{/if}
	</details>
</div>

<style>
	textarea.bad {
		border-color: var(--rust, #c2562b);
	}
	.paste-error {
		margin: 4px 0 0;
		color: var(--rust, #e07a4f);
	}
	.paste-ok {
		margin: 4px 0 0;
		color: var(--moss);
	}
	.bar {
		margin-bottom: 6px;
	}
	.radio {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		margin: 0 6px 0 0;
		font-size: 0.86rem;
		text-transform: capitalize;
	}
	.spacer {
		flex: 1;
	}
	.map {
		border-radius: var(--radius);
		overflow: hidden;
		border: 1px solid var(--line);
	}
	details textarea {
		min-height: 70px;
		font-family: var(--mono);
		font-size: 0.8rem;
		margin-top: 6px;
	}
</style>
