<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import { onDestroy, onMount } from 'svelte';
	import type { GeoJSONSource, Map as MLMap, MapGeoJSONFeature, Popup } from 'maplibre-gl';
	import {
		GARY_CENTER,
		GARY_ZOOM,
		baseStyle,
		interactiveLayers,
		momentLayers,
		snapshotLayers
	} from '$lib/map/style';
	import { yearToDate } from '$lib/time';
	import type { Picked } from '$lib/types';
	import { page } from '$app/state';

	let {
		year,
		minYear,
		maxYear,
		kinds,
		ghosts = true,
		moments = true,
		tag = null,
		basemap = 'fade',
		selected = null,
		center = GARY_CENTER,
		zoom = GARY_ZOOM,
		onselect,
		onmoments,
		onview
	}: {
		year: number;
		minYear: number;
		maxYear: number;
		kinds: string[];
		ghosts?: boolean;
		moments?: boolean;
		/** only entities carrying this tag (or a sub-trait) in the current year */
		tag?: string | null;
		/** fade: modern map fades as you go back · always · hidden */
		basemap?: 'fade' | 'always' | 'hidden';
		selected?: string | null;
		center?: [number, number];
		zoom?: number;
		onselect?: (p: Picked | null) => void;
		onmoments?: (fc: { features: GeoJSON.Feature[]; unplaced: unknown[] }) => void;
		onview?: (v: { center: [number, number]; zoom: number }) => void;
	} = $props();

	let container: HTMLDivElement;
	let map: MLMap | undefined;
	let popup: Popup | undefined;
	let ready = $state(false);
	let loading = $state(false);
	let failed = $state<string | null>(null);

	const cache = new Map<string, unknown>();
	let inflight: AbortController | undefined;
	let debounce: ReturnType<typeof setTimeout> | undefined;
	let lastSelected: string | null = null;

	async function getJSON(url: string, signal: AbortSignal) {
		if (cache.has(url)) return cache.get(url);
		const res = await fetch(url, { signal });
		if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
		const json = await res.json();
		cache.set(url, json);
		if (cache.size > 120) cache.delete(cache.keys().next().value!);
		return json;
	}

	async function refresh() {
		if (!map || !ready) return;
		inflight?.abort();
		const ctrl = (inflight = new AbortController());
		const at = yearToDate(year);
		const q = new URLSearchParams({ at, ghosts: ghosts ? '1' : '0' });
		if (kinds.length) q.set('kinds', [...kinds].sort().join(','));
		if (tag) q.set('tag', tag);
		loading = true;
		try {
			const [snap, mom] = await Promise.all([
				getJSON(`/api/snapshot?${q}`, ctrl.signal),
				moments ? getJSON(`/api/moments?at=${at}&years=5`, ctrl.signal) : null
			]);
			if (ctrl.signal.aborted) return;
			(map.getSource('snapshot') as GeoJSONSource).setData(snap as GeoJSON.FeatureCollection);
			const m = (mom ?? { type: 'FeatureCollection', features: [], unplaced: [] }) as GeoJSON.FeatureCollection & {
				unplaced: unknown[];
			};
			(map.getSource('moments') as GeoJSONSource).setData(m);
			onmoments?.(m);
			failed = null;
			applySelection(true);
		} catch (e) {
			if ((e as Error).name !== 'AbortError') failed = (e as Error).message;
		} finally {
			if (inflight === ctrl) loading = false;
		}
	}

	function applySelection(force = false) {
		if (!map || !ready) return;
		if (lastSelected && (force || lastSelected !== selected)) {
			map.setFeatureState({ source: 'snapshot', id: lastSelected }, { selected: false });
		}
		if (selected) map.setFeatureState({ source: 'snapshot', id: selected }, { selected: true });
		lastSelected = selected;
	}

	/** The present-day basemap fades as you travel back in time. */
	function applyEra() {
		if (!map || !ready) return;
		map.setLayoutProperty('basemap', 'visibility', basemap === 'hidden' ? 'none' : 'visible');
		if (basemap === 'always') {
			map.setPaintProperty('basemap', 'raster-opacity', 0.6);
			map.setPaintProperty('basemap', 'raster-saturation', -0.65);
			return;
		}
		const t = Math.max(0, Math.min(1, (year - minYear) / Math.max(1, maxYear - minYear)));
		const modern = Math.pow(t, 2.2);
		map.setPaintProperty('basemap', 'raster-opacity', 0.14 + 0.5 * modern);
		map.setPaintProperty('basemap', 'raster-saturation', -1 + 0.35 * modern);
	}

	export function flyTo(lon: number, lat: number, z = 16) {
		map?.flyTo({ center: [lon, lat], zoom: Math.max(map.getZoom(), z), speed: 1.4 });
	}

	onMount(async () => {
		const maplibregl = (await import('maplibre-gl')).default;
		map = new maplibregl.Map({
			container,
			style: baseStyle(page.data.settings),
			center,
			zoom,
			attributionControl: {
				compact: true,
				customAttribution: `<a href="${page.data.settings?.source_code_url}" target="_blank" rel="noopener">Source (AGPL)</a> · <a href="/about">About</a>`
			},
			maxZoom: 20
		});
		map.addControl(new maplibregl.NavigationControl({ visualizePitch: false }), 'top-right');
		map.addControl(new maplibregl.ScaleControl({ unit: 'imperial' }), 'bottom-right');
		popup = new maplibregl.Popup({ closeButton: false, closeOnClick: false, offset: 10 });

		map.on('load', () => {
			if (!map) return;
			map.addSource('snapshot', {
				type: 'geojson',
				data: { type: 'FeatureCollection', features: [] },
				promoteId: 'id'
			});
			map.addSource('moments', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			for (const l of snapshotLayers('snapshot')) map.addLayer(l);
			for (const l of momentLayers('moments')) map.addLayer(l);

			const targets = [...interactiveLayers('snapshot'), 'moments-dot'];
			const pick = (f: MapGeoJSONFeature): Picked => ({
				id: f.properties.id,
				slug: f.properties.slug,
				kind: f.properties.kind,
				name: f.properties.name
			});

			map.on('click', (e) => {
				const hits = map!.queryRenderedFeatures(e.point, { layers: targets });
				// Prefer the smallest thing under the cursor: moments > points > lines > areas
				const order = (f: MapGeoJSONFeature) =>
					f.layer.id.startsWith('moments') ? 0 : f.geometry.type === 'Point' ? 1 : f.geometry.type === 'LineString' ? 2 : 3;
				hits.sort((a, b) => order(a) - order(b));
				onselect?.(hits[0] ? pick(hits[0]) : null);
			});

			map.on('mousemove', (e) => {
				const hits = map!.queryRenderedFeatures(e.point, { layers: targets });
				const f = hits.find((h) => h.geometry.type !== 'Polygon') ?? hits[0];
				map!.getCanvas().style.cursor = f ? 'pointer' : '';
				if (!f) return void popup?.remove();
				const p = f.properties;
				const sub = p.ghost
					? 'gone by this year'
					: p.kind === 'space'
						? p.tenant || 'vacant'
						: (p.status_label ?? p.subtype ?? p.kind ?? '').toString().replace(/_/g, ' ');
				const node = document.createElement('div');
				const b = document.createElement('strong');
				b.textContent = p.name;
				const s = document.createElement('div');
				s.style.color = '#968a7a';
				s.textContent = p.from ? `${sub} · ${String(p.from).slice(0, 4)}` : sub;
				node.append(b, s);
				popup!.setLngLat(e.lngLat).setDOMContent(node).addTo(map!);
			});
			map.on('mouseout', () => popup?.remove());
			map.on('moveend', () => {
				const c = map!.getCenter();
				onview?.({ center: [+c.lng.toFixed(5), +c.lat.toFixed(5)], zoom: +map!.getZoom().toFixed(2) });
			});

			ready = true;
			applyEra();
			refresh();
		});
	});

	onDestroy(() => {
		clearTimeout(debounce);
		inflight?.abort();
		map?.remove();
	});

	// Refetch when the year or filters change (debounced so slider drags stay smooth)
	$effect(() => {
		void [year, ghosts, moments, tag, basemap, kinds.join(',')];
		if (!ready) return;
		applyEra();
		clearTimeout(debounce);
		debounce = setTimeout(refresh, 90);
	});

	$effect(() => {
		void selected;
		applySelection();
	});

</script>

<div class="map-wrap">
	<div class="map" bind:this={container}></div>
	{#if loading}<div class="loading" aria-live="polite">loading {year}…</div>{/if}
	{#if failed}<div class="failed notice error">Map data failed to load: {failed}</div>{/if}
</div>

<style>
	.map-wrap {
		position: relative;
		width: 100%;
		height: 100%;
	}
	.map {
		position: absolute;
		inset: 0;
	}
	.loading {
		position: absolute;
		top: 10px;
		left: 50%;
		transform: translateX(-50%);
		font-family: var(--mono);
		font-size: 0.75rem;
		color: var(--muted);
		background: rgba(20, 17, 15, 0.8);
		padding: 2px 10px;
		border-radius: 999px;
		pointer-events: none;
	}
	.failed {
		position: absolute;
		top: 10px;
		left: 10px;
		right: 60px;
		font-size: 0.85rem;
	}
</style>
