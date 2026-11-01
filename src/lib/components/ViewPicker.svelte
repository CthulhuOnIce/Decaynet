<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import { onDestroy, onMount } from 'svelte';
	import type { GeoJSONSource, Map as MLMap } from 'maplibre-gl';
	import { page } from '$app/state';
	import { baseStyle } from '$lib/map/style';

	/** Pick the site's default view and optional pan limits on a map. */
	let {
		lon = $bindable(),
		lat = $bindable(),
		zoom = $bindable(),
		bounds = $bindable()
	}: {
		lon: number;
		lat: number;
		zoom: number;
		/** "west,south,east,north" or '' for no limit */
		bounds: string;
	} = $props();

	let el: HTMLDivElement;
	let map: MLMap | undefined;
	let q = $state('');
	let results = $state<{ display_name: string; lat: string; lon: string; boundingbox: string[] }[]>([]);
	let searchError = $state<string | null>(null);

	const r = (n: number, d = 5) => Math.round(n * 10 ** d) / 10 ** d;

	function drawBounds() {
		const src = map?.getSource('limits') as GeoJSONSource | undefined;
		if (!src) return;
		const b = bounds.split(',').map(Number);
		src.setData(
			b.length === 4 && b.every(Number.isFinite)
				? { type: 'Feature', properties: {}, geometry: { type: 'Polygon', coordinates: [[[b[0], b[1]], [b[2], b[1]], [b[2], b[3]], [b[0], b[3]], [b[0], b[1]]]] } }
				: { type: 'FeatureCollection', features: [] }
		);
	}

	function useView() {
		if (!map) return;
		const c = map.getCenter();
		lon = r(c.lng);
		lat = r(c.lat);
		zoom = r(map.getZoom(), 1);
	}
	function limitToView() {
		if (!map) return;
		const b = map.getBounds();
		bounds = [b.getWest(), b.getSouth(), b.getEast(), b.getNorth()].map((n) => r(n, 4)).join(',');
	}

	/** Place search via OpenStreetMap Nominatim (light, interactive use only). */
	async function search(e?: Event) {
		e?.preventDefault();
		searchError = null;
		if (!q.trim()) return;
		try {
			const res = await fetch(`https://nominatim.openstreetmap.org/search?format=json&limit=5&q=${encodeURIComponent(q)}`, {
				headers: { 'Accept-Language': page.data.settings?.content_language ?? 'en' }
			});
			results = res.ok ? await res.json() : [];
			if (!results.length) searchError = 'No places found.';
		} catch {
			searchError = 'Place search is unavailable; pan the map instead.';
		}
	}
	function go(p: (typeof results)[number]) {
		const [s, n, w, e] = p.boundingbox.map(Number);
		map?.fitBounds([[w, s], [e, n]], { padding: 20 });
		results = [];
	}

	onMount(async () => {
		const maplibregl = (await import('maplibre-gl')).default;
		map = new maplibregl.Map({
			container: el,
			style: baseStyle(page.data.settings),
			center: [lon, lat],
			zoom,
			attributionControl: { compact: true }
		});
		map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
		map.on('load', () => {
			map!.setPaintProperty('basemap', 'raster-opacity', 0.75);
			map!.addSource('limits', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			map!.addLayer({ id: 'limits', type: 'line', source: 'limits', paint: { 'line-color': '#e0a23a', 'line-width': 2, 'line-dasharray': [3, 2] } });
			drawBounds();
		});
	});
	onDestroy(() => map?.remove());

	$effect(() => {
		void bounds;
		drawBounds();
	});
</script>

<div class="vp">
	<!-- not a <form>: this component lives inside the settings form -->
	<div class="row">
		<input bind:value={q} placeholder="Find a place: Detroit, Gary, Berlin…" style="flex: 1" onkeydown={(e) => e.key === 'Enter' && search(e)} />
		<button type="button" onclick={() => search()}>Find</button>
	</div>
	{#if searchError}<p class="hint">{searchError}</p>{/if}
	{#if results.length}
		<ul class="results">
			{#each results as p (p.display_name)}<li><button type="button" class="link" onclick={() => go(p)}>{p.display_name}</button></li>{/each}
		</ul>
	{/if}
	<div class="map" bind:this={el}></div>
	<div class="row">
		<button type="button" class="primary" onclick={useView}>Use this view as the default</button>
		<button type="button" onclick={limitToView}>Limit panning to this view</button>
		<button type="button" class="ghost" onclick={() => (bounds = '')}>No limit</button>
		<button type="button" class="ghost" onclick={() => map?.jumpTo({ center: [0, 20], zoom: 1.5 })}>Whole world</button>
	</div>
	<p class="hint">Search powered by OpenStreetMap Nominatim. Dashed box: the current pan limit.</p>
</div>

<style>
	.map {
		height: 340px;
		border-radius: var(--radius);
		overflow: hidden;
		border: 1px solid var(--line);
		margin: 8px 0;
	}
	.results {
		list-style: none;
		padding: 0;
		margin: 6px 0;
		font-size: 0.85rem;
	}
	.results li {
		padding: 3px 0;
	}
	button.link {
		background: none;
		border: 0;
		padding: 0;
		color: var(--rust-2);
		text-align: left;
		font: inherit;
		cursor: pointer;
	}
</style>
