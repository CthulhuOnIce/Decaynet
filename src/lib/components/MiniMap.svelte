<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import { onDestroy, onMount } from 'svelte';
	import { page } from '$app/state';
	import type { ExpressionSpecification, GeoJSONSource, Map as MLMap } from 'maplibre-gl';
	import { baseStyle, boundsOf, mapView } from '$lib/map/style';

	/** Features carry `current: boolean` (valid at the selected year) and `label`. */
	let { features, height = 260 }: { features: GeoJSON.Feature[]; height?: number } = $props();

	let el: HTMLDivElement;
	let map: MLMap | undefined;
	let ready = false;

	const fc = $derived<GeoJSON.FeatureCollection>({ type: 'FeatureCollection', features });

	function update() {
		if (!map || !ready) return;
		(map.getSource('geoms') as GeoJSONSource).setData(fc);
		const b = boundsOf(fc);
		if (b) map.fitBounds(b, { padding: 40, maxZoom: 16.5, duration: 0 });
	}

	onMount(async () => {
		const maplibregl = (await import('maplibre-gl')).default;
		map = new maplibregl.Map({
			container: el,
			style: baseStyle(page.data.settings),
			center: mapView(page.data.settings).center,
			zoom: mapView(page.data.settings).zoom,
			attributionControl: { compact: true },
			cooperativeGestures: true
		});
		map.on('load', () => {
			map!.addSource('geoms', { type: 'geojson', data: fc });
			const cur: ExpressionSpecification = ['boolean', ['get', 'current'], false];
			map!.addLayer({
				id: 'fill',
				type: 'fill',
				source: 'geoms',
				filter: ['==', ['geometry-type'], 'Polygon'],
				paint: { 'fill-color': ['case', cur, '#c2562b', '#8c8173'], 'fill-opacity': ['case', cur, 0.35, 0.08] }
			});
			const notPoint: ExpressionSpecification = ['!=', ['geometry-type'], 'Point'];
			map!.addLayer({
				id: 'line-old',
				type: 'line',
				source: 'geoms',
				filter: ['all', notPoint, ['!', cur]],
				paint: { 'line-color': '#8c8173', 'line-width': 1.5, 'line-dasharray': [3, 1.5] }
			});
			map!.addLayer({
				id: 'line-cur',
				type: 'line',
				source: 'geoms',
				filter: ['all', notPoint, cur],
				paint: { 'line-color': '#e07a4f', 'line-width': 3 }
			});
			map!.addLayer({
				id: 'pt',
				type: 'circle',
				source: 'geoms',
				filter: ['==', ['geometry-type'], 'Point'],
				paint: {
					'circle-radius': ['case', cur, 8, 5],
					'circle-color': ['case', cur, '#c2562b', 'rgba(0,0,0,0)'],
					'circle-stroke-color': ['case', cur, '#17130f', '#8c8173'],
					'circle-stroke-width': 2
				}
			});
			ready = true;
			update();
		});
	});

	$effect(() => {
		void fc;
		update();
	});

	onDestroy(() => map?.remove());
</script>

<div class="mini" style:height="{height}px" bind:this={el}></div>

<style>
	.mini {
		width: 100%;
		border-radius: var(--radius);
		overflow: hidden;
		border: 1px solid var(--line);
	}
</style>
