<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import { onDestroy, onMount } from 'svelte';
	import { page } from '$app/state';
	import type { GeoJSONSource, Map as MLMap } from 'maplibre-gl';
	import { baseStyle, boundsOf, mapView } from '$lib/map/style';

	type Mode = 'point' | 'line' | 'polygon';

	let {
		name = 'geojson',
		mode: initialMode = 'point',
		context = [],
		height = 360,
		snap = true
	}: {
		name?: string;
		mode?: Mode;
		/** existing shapes drawn for reference */
		context?: GeoJSON.Feature[];
		height?: number;
		/** snap clicks to nearby vertices of the context shapes (shared walls, street corners) */
		snap?: boolean;
	} = $props();

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
	let pts = $state<[number, number][]>([]);
	let el: HTMLDivElement;
	let map: MLMap | undefined;
	let ready = false;

	const geometry = $derived.by((): GeoJSON.Geometry | null => {
		if (mode === 'point') return pts.length ? { type: 'Point', coordinates: pts[pts.length - 1] } : null;
		if (mode === 'line') return pts.length >= 2 ? { type: 'LineString', coordinates: pts } : null;
		return pts.length >= 3 ? { type: 'Polygon', coordinates: [[...pts, pts[0]]] } : null;
	});
	const value = $derived(geometry ? JSON.stringify(geometry) : '');

	function draw() {
		if (!map || !ready) return;
		const features: GeoJSON.Feature[] = pts.map((c) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: c }, properties: { vertex: true } }));
		if (geometry && geometry.type !== 'Point') features.push({ type: 'Feature', geometry, properties: {} });
		(map.getSource('draft') as GeoJSONSource).setData({ type: 'FeatureCollection', features });
	}

	onMount(async () => {
		const maplibregl = (await import('maplibre-gl')).default;
		map = new maplibregl.Map({ container: el, style: baseStyle(page.data.settings), ...mapView(page.data.settings, 3), attributionControl: { compact: true } });
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
			const b = context.length ? boundsOf({ type: 'FeatureCollection', features: context }) : null;
			if (b) m.fitBounds(b, { padding: 60, maxZoom: 17, duration: 0 });
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
		void geometry;
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
	<details>
		<summary class="muted small">…or paste GeoJSON geometry</summary>
		<textarea name="{name}_text" rows="4" placeholder={'{"type":"Polygon","coordinates":[[[-87.33,41.60],…]]}'}></textarea>
	</details>
</div>

<style>
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
