<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import { onDestroy, onMount, untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import { invalidateAll } from '$app/navigation';
	import type { GeoJSONSource, ImageSource, Map as MLMap, Marker } from 'maplibre-gl';
	import YearSlider from '$lib/components/YearSlider.svelte';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import TemporalFields from '$lib/components/TemporalFields.svelte';
	import { baseStyle, snapshotLayers } from '$lib/map/style';
	import { mediaSrc } from '$lib/media';
	import { can } from '$lib/perms';
	import { browserClient } from '$lib/supabaseBrowser';
	import { toFuzzyInput, yearToDate } from '$lib/time';
	import type { MapLayer } from '$lib/types';

	let { data, form } = $props();

	type Tool = 'overlay' | 'trace' | 'area' | 'import';
	type Corners = [[number, number], [number, number], [number, number], [number, number]];

	let tool = $state<Tool>(can('manage_layers') ? 'overlay' : 'trace');
	let year = $state(untrack(() => data.settings.default_year));
	let ready = $state(false);
	let mapEl: HTMLDivElement;
	let topEl: HTMLDivElement;
	let map: MLMap | undefined;
	let top: MLMap | undefined;
	let maplibre: typeof import('maplibre-gl') | undefined;
	let lastSnap: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };
	let refreshKey = $state(0);

	// ---------------------------------------------------------------- overlay
	let layerId = $state('');
	let opacity = $state(0.7);
	let overlayHidden = $state(false); // flicker (hold F)
	let compare = $state<'blend' | 'swipe'>('blend');
	let swipe = $state(0.5);
	const layer = $derived<MapLayer | null>(data.layers.find((l) => l.id === layerId) ?? null);

	// Georeferencing a scanned image: drag four corners into place
	let georef = $state<{ id?: string; image_path: string; url: string; corners: Corners; title: string; depicts_from: string; depicts_to: string; attribution: string; notes: string } | null>(null);
	let markers: Marker[] = [];
	let uploadBusy = $state(false);
	let uploadError = $state<string | null>(null);

	const activeSource = $derived.by(() => {
		if (georef) return { kind: 'image' as const, url: georef.url, corners: georef.corners };
		if (!layer) return null;
		if (layer.kind === 'image' && layer.image_path && layer.corners)
			return { kind: 'image' as const, url: mediaSrc(layer.image_path)!, corners: layer.corners as Corners };
		if (layer.tile_url) return { kind: 'xyz' as const, url: layer.tile_url, layer };
		return null;
	});

	function addOverlayTo(m: MLMap, before?: string) {
		if (m.getLayer('overlay')) m.removeLayer('overlay');
		if (m.getSource('overlay')) m.removeSource('overlay');
		const src = activeSource;
		if (!src) return;
		if (src.kind === 'image') m.addSource('overlay', { type: 'image', url: src.url, coordinates: src.corners });
		else
			m.addSource('overlay', {
				type: 'raster',
				tiles: [src.url],
				tileSize: src.layer.tile_size,
				minzoom: src.layer.min_zoom,
				maxzoom: src.layer.max_zoom,
				...(src.layer.bounds ? { bounds: src.layer.bounds } : {})
			});
		m.addLayer({ id: 'overlay', type: 'raster', source: 'overlay', paint: { 'raster-opacity': opacity, 'raster-fade-duration': 0 } }, before);
	}

	function applyOverlay() {
		if (!map || !ready) return;
		if (compare === 'swipe' && top) {
			if (map.getLayer('overlay')) map.removeLayer('overlay');
			if (map.getSource('overlay')) map.removeSource('overlay');
			if (top.isStyleLoaded()) addOverlayTo(top);
			else top.once('load', () => addOverlayTo(top!));
		} else {
			if (top?.getLayer('overlay')) top.removeLayer('overlay');
			addOverlayTo(map, 'snapshot-district-fill');
		}
		applyOpacity();
	}

	function applyOpacity() {
		const m = compare === 'swipe' ? top : map;
		if (m?.getLayer('overlay')) m.setPaintProperty('overlay', 'raster-opacity', overlayHidden ? 0 : compare === 'swipe' ? 1 : opacity);
	}

	function ensureTop() {
		if (top || !maplibre || !map) return;
		top = new maplibre.Map({
			container: topEl,
			style: { version: 8, sources: {}, layers: [] },
			center: map.getCenter(),
			zoom: map.getZoom(),
			bearing: map.getBearing(),
			interactive: false,
			attributionControl: false
		});
	}

	function setCorners(c: Corners) {
		if (!georef) return;
		georef.corners = c;
		const src = map?.getSource('overlay') as ImageSource | undefined;
		src?.setCoordinates(c);
		(top?.getSource('overlay') as ImageSource | undefined)?.setCoordinates(c);
	}

	function placeMarkers() {
		markers.forEach((m) => m.remove());
		markers = [];
		if (!georef || !map || !maplibre) return;
		const mk = (cls: string, title: string) => {
			const el = document.createElement('div');
			el.className = `handle ${cls}`;
			el.title = title;
			return el;
		};
		georef.corners.forEach((c, i) => {
			const m = new maplibre!.Marker({ element: mk('corner', ['top-left', 'top-right', 'bottom-right', 'bottom-left'][i]), draggable: true })
				.setLngLat(c)
				.addTo(map!);
			m.on('drag', () => {
				const ll = m.getLngLat();
				const next = georef!.corners.map((x) => [...x]) as Corners;
				next[i] = [ll.lng, ll.lat];
				setCorners(next);
				moveCenterMarker();
			});
			markers.push(m);
		});
		// Centre handle moves the whole sheet
		const centre = new maplibre.Marker({ element: mk('move', 'Drag to move the whole sheet'), draggable: true })
			.setLngLat(centroid(georef.corners))
			.addTo(map);
		let last = centre.getLngLat();
		centre.on('dragstart', () => (last = centre.getLngLat()));
		centre.on('drag', () => {
			const ll = centre.getLngLat();
			const dx = ll.lng - last.lng;
			const dy = ll.lat - last.lat;
			last = ll;
			const next = georef!.corners.map(([x, y]) => [x + dx, y + dy]) as Corners;
			setCorners(next);
			next.forEach((c, i) => markers[i].setLngLat(c));
		});
		markers.push(centre);
	}
	const centroid = (c: Corners): [number, number] => [c.reduce((a, p) => a + p[0], 0) / 4, c.reduce((a, p) => a + p[1], 0) / 4];
	const moveCenterMarker = () => georef && markers[4]?.setLngLat(centroid(georef.corners));

	/** Rotate / scale the sheet about its centre (fine adjustments). */
	function transform(rotateDeg: number, scale: number) {
		if (!georef || !map) return;
		const c = map.project(centroid(georef.corners));
		const a = (rotateDeg * Math.PI) / 180;
		const next = georef.corners.map((ll) => {
			const p = map!.project(ll);
			const x = (p.x - c.x) * scale;
			const y = (p.y - c.y) * scale;
			const r = map!.unproject([c.x + x * Math.cos(a) - y * Math.sin(a), c.y + x * Math.sin(a) + y * Math.cos(a)]);
			return [r.lng, r.lat];
		}) as Corners;
		setCorners(next);
		placeMarkers();
	}

	async function uploadScan(e: Event) {
		const file = (e.currentTarget as HTMLInputElement).files?.[0];
		if (!file || !map) return;
		uploadBusy = true;
		uploadError = null;
		try {
			const ext = file.name.split('.').pop()?.toLowerCase() ?? 'jpg';
			const path = `overlays/${crypto.randomUUID()}.${ext}`;
			const { error } = await browserClient().storage.from('media').upload(path, file, { contentType: file.type });
			if (error) throw error;
			const url = mediaSrc(path)!;
			const img = new Image();
			img.src = url;
			await img.decode();
			// Start at ~60% of the view, preserving the scan's aspect ratio on screen
			const { clientWidth: W, clientHeight: H } = map.getContainer();
			const w = Math.min(W * 0.6, ((H * 0.6) * img.width) / img.height);
			const h = (w * img.height) / img.width;
			const x0 = (W - w) / 2;
			const y0 = (H - h) / 2;
			const ll = (x: number, y: number): [number, number] => {
				const p = map!.unproject([x, y]);
				return [p.lng, p.lat];
			};
			layerId = '';
			georef = {
				image_path: path,
				url,
				corners: [ll(x0, y0), ll(x0 + w, y0), ll(x0 + w, y0 + h), ll(x0, y0 + h)],
				title: file.name.replace(/\.[^.]+$/, '').replace(/[_-]+/g, ' '),
				depicts_from: String(year),
				depicts_to: '',
				attribution: '',
				notes: ''
			};
		} catch (err) {
			uploadError = (err as Error).message;
		} finally {
			uploadBusy = false;
		}
	}

	function editAlignment() {
		if (!layer || layer.kind !== 'image' || !layer.image_path || !layer.corners) return;
		georef = {
			id: layer.id,
			image_path: layer.image_path,
			url: mediaSrc(layer.image_path)!,
			corners: layer.corners.map((c) => [...c]) as Corners,
			title: layer.title,
			depicts_from: toFuzzyInput(layer.depicts_from, 'year'),
			depicts_to: toFuzzyInput(layer.depicts_to, 'year'),
			attribution: layer.attribution ?? '',
			notes: layer.notes ?? ''
		};
	}

	function chooseLayer(id: string) {
		layerId = id;
		georef = null;
		const l = data.layers.find((x) => x.id === id);
		if (l) {
			opacity = l.default_opacity;
			if (l.depicts_from) year = Number(l.depicts_from.slice(0, 4));
			if (l.kind === 'image' && l.corners && map) {
				const xs = l.corners.map((c) => c[0]);
				const ys = l.corners.map((c) => c[1]);
				map.fitBounds([[Math.min(...xs), Math.min(...ys)], [Math.max(...xs), Math.max(...ys)]], { padding: 40 });
			} else if (l.bounds && map) map.fitBounds([[l.bounds[0], l.bounds[1]], [l.bounds[2], l.bounds[3]]], { padding: 40 });
		}
	}

	// ---------------------------------------------------------------- drawing (trace + area)
	let drawMode = $state<'polygon' | 'line' | 'point'>('polygon');
	let pts = $state<[number, number][]>([]);
	const drawing = $derived((tool === 'trace' || tool === 'area') && !georef);
	const effectiveMode = $derived(tool === 'area' ? 'polygon' : drawMode);
	const geometry = $derived.by((): GeoJSON.Geometry | null => {
		if (effectiveMode === 'point') return pts.length ? { type: 'Point', coordinates: pts[pts.length - 1] } : null;
		if (effectiveMode === 'line') return pts.length >= 2 ? { type: 'LineString', coordinates: pts } : null;
		return pts.length >= 3 ? { type: 'Polygon', coordinates: [[...pts, pts[0]]] } : null;
	});
	const geojsonText = $derived(geometry ? JSON.stringify(geometry) : '');

	function snapshotVertices(): [number, number][] {
		const out: [number, number][] = [];
		const walk = (c: unknown): void => {
			if (Array.isArray(c) && typeof c[0] === 'number') out.push([c[0] as number, c[1] as number]);
			else if (Array.isArray(c)) c.forEach(walk);
		};
		for (const f of lastSnap.features) if (f.geometry && 'coordinates' in f.geometry) walk(f.geometry.coordinates);
		return out;
	}

	function drawDraft() {
		if (!map || !ready) return;
		const feats: GeoJSON.Feature[] = pts.map((c) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: c }, properties: {} }));
		if (geometry && geometry.type !== 'Point') feats.unshift({ type: 'Feature', geometry, properties: {} });
		(map.getSource('draft') as GeoJSONSource).setData({ type: 'FeatureCollection', features: feats });
	}

	// ---------------------------------------------------------------- area preview
	let previewIds = $state<string[]>([]);
	$effect(() => {
		const p = form && 'preview' in form ? form.preview : null;
		previewIds = p ? p.map((r) => r.id) : [];
	});
	let highlighted: string[] = [];
	function highlight(ids: string[]) {
		if (!map || !ready) return;
		for (const id of highlighted) map.setFeatureState({ source: 'snapshot', id }, { selected: false });
		for (const id of ids) map.setFeatureState({ source: 'snapshot', id }, { selected: true });
		highlighted = ids;
	}

	// ---------------------------------------------------------------- import
	let importFc = $state<GeoJSON.FeatureCollection | null>(null);
	let importText = $state('');
	let importError = $state<string | null>(null);
	const importProps = $derived(
		importFc ? [...new Set(importFc.features.flatMap((f) => Object.keys(f.properties ?? {})))].sort() : []
	);
	async function readImport(e: Event) {
		importError = null;
		const file = (e.currentTarget as HTMLInputElement).files?.[0];
		if (!file) return;
		try {
			const text = await file.text();
			const json = JSON.parse(text);
			if (json.type !== 'FeatureCollection') throw new Error('Expected a GeoJSON FeatureCollection (EPSG:4326 lon/lat).');
			importFc = json;
			importText = text;
			const src = map?.getSource('import') as GeoJSONSource | undefined;
			src?.setData(json);
			const xs: number[] = [];
			const ys: number[] = [];
			const walk = (c: unknown): void => {
				if (Array.isArray(c) && typeof c[0] === 'number') {
					xs.push(c[0] as number);
					ys.push(c[1] as number);
				} else if (Array.isArray(c)) c.forEach(walk);
			};
			json.features.forEach((f: GeoJSON.Feature) => f.geometry && 'coordinates' in f.geometry && walk(f.geometry.coordinates));
			if (xs.length && map) map.fitBounds([[Math.min(...xs), Math.min(...ys)], [Math.max(...xs), Math.max(...ys)]], { padding: 40, maxZoom: 17 });
		} catch (err) {
			importFc = null;
			importText = '';
			importError = (err as Error).message;
		}
	}
	function clearImport() {
		importFc = null;
		importText = '';
		(map?.getSource('import') as GeoJSONSource | undefined)?.setData({ type: 'FeatureCollection', features: [] });
	}

	// ---------------------------------------------------------------- map lifecycle
	let fetchTimer: ReturnType<typeof setTimeout> | undefined;
	async function refresh() {
		if (!map || !ready) return;
		const res = await fetch(`/api/snapshot?at=${yearToDate(year)}&ghosts=1&_=${refreshKey}`);
		if (!res.ok) return;
		lastSnap = await res.json();
		(map.getSource('snapshot') as GeoJSONSource).setData(lastSnap);
		highlight(previewIds);
	}

	onMount(async () => {
		maplibre = ((await import('maplibre-gl')) as unknown as { default: typeof import('maplibre-gl') }).default;
		map = new maplibre.Map({
			container: mapEl,
			style: baseStyle(data.settings),
			center: [data.settings.map_center_lon, data.settings.map_center_lat],
			zoom: Math.max(15, data.settings.map_zoom),
			attributionControl: { compact: true },
			maxZoom: 21
		});
		const mm = map;
		mm.addControl(new maplibre.NavigationControl(), 'top-right');
		mm.doubleClickZoom.disable();
		mm.on('load', () => {
			const m = map!;
			m.setPaintProperty('basemap', 'raster-opacity', 0.45);
			m.addSource('snapshot', { type: 'geojson', data: { type: 'FeatureCollection', features: [] }, promoteId: 'id' });
			for (const l of snapshotLayers('snapshot')) m.addLayer(l);
			m.addSource('import', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			m.addLayer({ id: 'import-fill', type: 'fill', source: 'import', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#8fb3c9', 'fill-opacity': 0.3 } });
			m.addLayer({ id: 'import-line', type: 'line', source: 'import', paint: { 'line-color': '#8fb3c9', 'line-width': 1.5 } });
			m.addLayer({ id: 'import-pt', type: 'circle', source: 'import', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 4, 'circle-color': '#8fb3c9' } });
			m.addSource('draft', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			m.addLayer({ id: 'draft-fill', type: 'fill', source: 'draft', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#f2c14e', 'fill-opacity': 0.25 } });
			m.addLayer({ id: 'draft-line', type: 'line', source: 'draft', filter: ['!=', ['geometry-type'], 'Point'], paint: { 'line-color': '#f2c14e', 'line-width': 2.5 } });
			m.addLayer({ id: 'draft-pt', type: 'circle', source: 'draft', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 4.5, 'circle-color': '#f2c14e', 'circle-stroke-color': '#17130f', 'circle-stroke-width': 1.5 } });

			m.on('click', (e) => {
				if (!drawing) return;
				let c: [number, number] = [+e.lngLat.lng.toFixed(7), +e.lngLat.lat.toFixed(7)];
				let best = 10;
				for (const v of [...snapshotVertices(), ...pts]) {
					const p = m.project(v);
					const d = Math.hypot(p.x - e.point.x, p.y - e.point.y);
					if (d < best) {
						best = d;
						c = v;
					}
				}
				pts = effectiveMode === 'point' ? [c] : [...pts, c];
			});
			m.on('move', () => top?.jumpTo({ center: m.getCenter(), zoom: m.getZoom(), bearing: m.getBearing(), pitch: m.getPitch() }));
			ready = true;
			applyOverlay();
			refresh();
		});
	});

	onDestroy(() => {
		clearTimeout(fetchTimer);
		markers.forEach((m) => m.remove());
		top?.remove();
		map?.remove();
	});

	$effect(() => {
		void [year, refreshKey];
		if (!ready) return;
		clearTimeout(fetchTimer);
		fetchTimer = setTimeout(refresh, 100);
	});
	$effect(() => {
		void [activeSource?.url, layerId, compare, !!georef];
		if (!ready) return;
		if (compare === 'swipe') ensureTop();
		untrack(applyOverlay);
	});
	$effect(() => {
		void [opacity, overlayHidden];
		untrack(applyOpacity);
	});
	$effect(() => {
		void [georef?.image_path, georef?.id, ready];
		untrack(placeMarkers);
	});
	$effect(() => {
		void [geometry, pts.length];
		untrack(drawDraft);
	});
	$effect(() => {
		void previewIds;
		untrack(() => highlight(previewIds));
	});
	$effect(() => {
		if (map) map.getCanvas().style.cursor = drawing ? 'crosshair' : '';
	});

	function onkey(e: KeyboardEvent) {
		const t = e.target as HTMLElement;
		if (t.closest('input, textarea, select')) return;
		if (e.key === 'f' && !e.repeat) overlayHidden = true;
		if (drawing && e.key === 'Backspace') {
			e.preventDefault();
			pts = pts.slice(0, -1);
		}
		if (drawing && e.key === 'Escape') pts = [];
	}
	function onkeyup(e: KeyboardEvent) {
		if (e.key === 'f') overlayHidden = false;
	}

	// Swipe handle
	let dragging = false;
	function swipeMove(e: PointerEvent) {
		if (!dragging || !mapEl) return;
		const r = mapEl.getBoundingClientRect();
		swipe = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
	}

	function after(clearDraw = true) {
		return async ({ result, update }: { result: { type: string }; update: (o?: { reset?: boolean }) => Promise<void> }) => {
			await update({ reset: false });
			if (result.type === 'success') {
				refreshKey++;
				if (clearDraw) pts = [];
			}
		};
	}

	const TOOLS: { id: Tool; label: string; ok: boolean }[] = $derived([
		{ id: 'overlay', label: 'Overlays', ok: can('manage_layers') || data.layers.length > 0 },
		{ id: 'trace', label: 'Trace', ok: can('edit_content') },
		{ id: 'area', label: 'Area change', ok: can('bulk_edit') },
		{ id: 'import', label: 'Import', ok: can('bulk_edit') }
	]);
	const msg = $derived(form && form.tool === tool ? form : null);
	const spatialKinds = $derived(data.vocab.kinds.filter((k) => !['person', 'organization', 'event', 'media'].includes(k.id)));
</script>

<svelte:window onkeydown={onkey} onkeyup={onkeyup} onpointermove={swipeMove} onpointerup={() => (dragging = false)} />
<svelte:head><title>Workbench · {data.settings.site_name}</title></svelte:head>

<div class="wb">
	<aside class="panel">
		<div class="tabs">
			{#each TOOLS.filter((t) => t.ok) as t (t.id)}
				<button class:on={tool === t.id} onclick={() => ((tool = t.id), (pts = []))}>{t.label}</button>
			{/each}
		</div>

		{#if msg && 'error' in msg && msg.error}<p class="notice error small">{msg.error}</p>{/if}
		{#if msg && 'ok' in msg && msg.ok}
			<p class="notice ok small">{msg.ok} {#if 'slug' in msg && msg.slug}<a href="/e/{msg.slug}">Open page →</a>{/if}</p>
		{/if}

		<!-- ======================= OVERLAYS ======================= -->
		{#if tool === 'overlay'}
			<p class="hint">Lay a Sanborn sheet, plat or aerial over today's map and the wiki's data, then trace what you see.</p>
			<div class="field">
				<label for="ov">Overlay</label>
				<select id="ov" value={layerId} onchange={(e) => chooseLayer(e.currentTarget.value)}>
					<option value="">none</option>
					{#each data.layers as l (l.id)}
						<option value={l.id}>{l.title} ({l.depicts_from?.slice(0, 4) ?? '?'}) {l.kind === 'image' ? '· scan' : '· tiles'}</option>
					{/each}
				</select>
			</div>
			{#if activeSource}
				<div class="field">
					<label for="op">Opacity {Math.round(opacity * 100)}%</label>
					<input id="op" type="range" min="0" max="1" step="0.05" bind:value={opacity} disabled={compare === 'swipe'} />
				</div>
				<div class="seg">
					<button class:on={compare === 'blend'} onclick={() => (compare = 'blend')}>Blend</button>
					<button class:on={compare === 'swipe'} onclick={() => (compare = 'swipe')}>Swipe</button>
				</div>
				<p class="hint">Hold <kbd>F</kbd> to flicker the overlay off and back on.</p>
				{#if layer?.kind === 'image' && !georef && can('manage_layers')}
					<button onclick={editAlignment}>Adjust alignment</button>
				{/if}
			{/if}

			{#if can('manage_layers')}
				<hr />
				{#if !georef}
					<h3>Georeference a scan</h3>
					<p class="hint">Upload a scanned map (JPG/PNG). It appears on the map with four corner handles. Drag each corner to the matching street corner, then save.</p>
					<input type="file" accept="image/png,image/jpeg,image/webp" onchange={uploadScan} disabled={uploadBusy} />
					{#if uploadBusy}<p class="muted small">Uploading…</p>{/if}
					{#if uploadError}<p class="notice error small">{uploadError}</p>{/if}
					<p class="hint">Already georeferenced elsewhere (Map Warper, Allmaps)? <a href="/layers">Add its tile URL →</a></p>
				{:else}
					<h3>{georef.id ? 'Adjust alignment' : 'Place the scan'}</h3>
					<p class="hint">Drag the <span class="sw corner"></span> corners onto matching intersections; drag <span class="sw move"></span> to move the whole sheet. Lower the opacity to see streets underneath.</p>
					<div class="row nudges">
						<button title="Rotate left" onclick={() => transform(-1, 1)}>⟲ 1°</button>
						<button title="Rotate right" onclick={() => transform(1, 1)}>⟳ 1°</button>
						<button title="Shrink" onclick={() => transform(0, 0.98)}>− 2%</button>
						<button title="Grow" onclick={() => transform(0, 1.02)}>+ 2%</button>
					</div>
					<form
						method="post"
						action="?/saveOverlay"
						class="stack"
						use:enhance={() =>
							async ({ result, update }) => {
								await update({ reset: false });
								if (result.type === 'success') {
									await invalidateAll();
									const id = result.data?.layerId as string | undefined;
									georef = null;
									if (id) layerId = id;
								}
							}}
					>
						<input type="hidden" name="tool" value="overlay" />
						<input type="hidden" name="id" value={georef.id ?? ''} />
						<input type="hidden" name="image_path" value={georef.image_path} />
						<input type="hidden" name="corners" value={JSON.stringify(georef.corners)} />
						<input type="hidden" name="opacity" value={opacity} />
						<div><label for="gt">Title</label><input id="gt" name="title" bind:value={georef.title} required /></div>
						<div class="fields">
							<div><label for="gf">Depicts from</label><input id="gf" name="depicts_from" bind:value={georef.depicts_from} placeholder="1925" /></div>
							<div><label for="gto">until</label><input id="gto" name="depicts_to" bind:value={georef.depicts_to} placeholder="1925" /></div>
						</div>
						<div><label for="ga">Attribution</label><input id="ga" name="attribution" bind:value={georef.attribution} placeholder="Library of Congress, Sanborn Maps" /></div>
						<div>
							<label for="gs">Source</label>
							<select id="gs" name="source_id"><option value="">(none)</option>{#each data.sources as s (s.id)}<option value={s.id}>{s.title}</option>{/each}</select>
						</div>
						<div><label for="gn">Notes</label><input id="gn" name="notes" bind:value={georef.notes} placeholder="Sheet 12; aligned on Broadway & 5th" /></div>
						<div class="row">
							<button class="primary">Save overlay</button>
							<button type="button" class="ghost" onclick={() => (georef = null)}>Cancel</button>
						</div>
					</form>
				{/if}
			{/if}
		{/if}

		<!-- ======================= TRACE ======================= -->
		{#if tool === 'trace'}
			<p class="hint">Click to place vertices over the overlay. Corners snap to existing shapes. <kbd>Backspace</kbd> undoes, <kbd>Esc</kbd> clears.</p>
			<div class="seg">
				{#each ['polygon', 'line', 'point'] as const as m (m)}
					<button class:on={drawMode === m} onclick={() => ((drawMode = m), (pts = []))}>{m}</button>
				{/each}
			</div>
			<p class="muted small">{pts.length} vertices {geometry ? '· ready' : ''}</p>
			<form method="post" action="?/trace" class="stack" use:enhance={() => after()}>
				<input type="hidden" name="tool" value="trace" />
				<input type="hidden" name="geojson" value={geojsonText} />
				<div>
					<label for="te">Add to existing page…</label>
					<EntityPicker id="te" name="entity_id" />
				</div>
				<p class="muted small">…or create a new one:</p>
				<div class="fields">
					<div><label for="tn">Name</label><input id="tn" name="name" placeholder="Hardware store" /></div>
					<div>
						<label for="tk">Kind</label>
						<select id="tk" name="kind">{#each spatialKinds as k (k.id)}<option value={k.id} selected={k.id === 'building'}>{k.label}</option>{/each}</select>
					</div>
					<div>
						<label for="ts">Condition</label>
						<select id="ts" name="status"><option value="">(unknown)</option>{#each data.vocab.statuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}</select>
					</div>
					<div>
						<label for="tr">Role</label>
						<select id="tr" name="role">{#each ['footprint', 'shape', 'centerline', 'boundary', 'point'] as r (r)}<option>{r}</option>{/each}</select>
					</div>
				</div>
				<TemporalFields
					sources={data.sources}
					idPrefix="tr"
					values={{ valid_from: layer?.depicts_from ?? `${year}-01-01`, valid_from_precision: 'year', confidence: 'probable' }}
					fromLabel="Seen from"
					toLabel="Until"
				/>
				<button class="primary" disabled={!geometry}>Save shape</button>
			</form>
		{/if}

		<!-- ======================= AREA ======================= -->
		{#if tool === 'area'}
			<p class="hint">
				When a whole area's layout changed (a highway cut through, a block was cleared, streets were re-platted), draw around it
				and end everything inside at once. Things become ghosts after that date; nothing is deleted.
			</p>
			<p class="muted small">{pts.length} vertices {geometry ? '· ready' : '· draw a polygon'}</p>
			<form method="post" action="?/previewArea" class="stack" use:enhance={() => after(false)}>
				<input type="hidden" name="tool" value="area" />
				<input type="hidden" name="geojson" value={geojsonText} />
				<div><label for="aat">Changed in</label><input id="aat" name="at" value={String(year)} placeholder="1956" required /></div>
				<div class="kinds">
					{#each ['building', 'street', 'site', 'parcel', 'space', 'infrastructure', 'water', 'landform'] as k (k)}
						<label class="check"><input type="checkbox" name="kinds" value={k} checked={['building', 'street', 'site', 'parcel', 'space'].includes(k)} />{k}</label>
					{/each}
				</div>
				<button disabled={!geometry}>Preview what's inside</button>
			</form>
			{#if msg && 'preview' in msg && msg.preview}
				<form method="post" action="?/retireArea" class="stack" use:enhance={() => after()}>
					<input type="hidden" name="tool" value="area" />
					<input type="hidden" name="geojson" value={geojsonText} />
					<input type="hidden" name="at" value={String(year)} />
					<ul class="plain-list preview">
						{#each msg.preview as r (r.id)}
							<li>
								<label class="check">
									<input type="checkbox" name="ids" value={r.id} bind:group={previewIds} />
									{r.name} <span class="muted small">{r.kind}{r.status ? ` · ${r.status}` : ''}</span>
								</label>
							</li>
						{:else}
							<li class="muted small">Nothing standing there in that year.</li>
						{/each}
					</ul>
					{#if msg.preview.length}
						<div class="fields">
							<div>
								<label for="ast">Mark as</label>
								<select id="ast" name="status">
									{#each data.vocab.statuses.filter((s) => s.decay_level >= 4) as s (s.id)}<option value={s.id} selected={s.id === 'demolished'}>{s.label}</option>{/each}
								</select>
							</div>
							<div>
								<label for="asrc">Source</label>
								<select id="asrc" name="source_id"><option value="">(uncited)</option>{#each data.sources as s (s.id)}<option value={s.id}>{s.title}</option>{/each}</select>
							</div>
						</div>
						<div><label for="anote">Note</label><input id="anote" name="note" placeholder="Cleared for the Indiana Toll Road" /></div>
						<button class="primary">End {previewIds.length} in {year}</button>
					{/if}
				</form>
			{/if}
		{/if}

		<!-- ======================= IMPORT ======================= -->
		{#if tool === 'import'}
			<p class="hint">
				Bring in GIS data: building footprints, parcels, digitized street grids. Upload a GeoJSON FeatureCollection in lon/lat
				(EPSG:4326). Each feature becomes a page with a dated shape.
			</p>
			<input type="file" accept=".geojson,.json,application/geo+json,application/json" onchange={readImport} />
			{#if importError}<p class="notice error small">{importError}</p>{/if}
			{#if importFc}
				<p class="small">{importFc.features.length} features · previewed in blue <button class="ghost" onclick={clearImport}>clear</button></p>
				<form method="post" action="?/import" class="stack" use:enhance={() => after(false)}>
					<input type="hidden" name="tool" value="import" />
					<input type="hidden" name="fc" value={importText} />
					<div class="fields">
						<div>
							<label for="ik">Kind</label>
							<select id="ik" name="kind">{#each spatialKinds as k (k.id)}<option value={k.id} selected={k.id === 'building'}>{k.label}</option>{/each}</select>
						</div>
						<div>
							<label for="ir">Role</label>
							<select id="ir" name="role">{#each ['footprint', 'shape', 'centerline', 'boundary', 'point'] as r (r)}<option>{r}</option>{/each}</select>
						</div>
						<div>
							<label for="inp">Name from property</label>
							<select id="inp" name="name_prop">{#each importProps as p (p)}<option selected={/^name$/i.test(p)}>{p}</option>{/each}</select>
						</div>
						<div>
							<label for="ifp">Start year property</label>
							<select id="ifp" name="from_prop"><option value="">(none)</option>{#each importProps as p (p)}<option>{p}</option>{/each}</select>
						</div>
						<div>
							<label for="itp">End year property</label>
							<select id="itp" name="to_prop"><option value="">(none)</option>{#each importProps as p (p)}<option>{p}</option>{/each}</select>
						</div>
						<div>
							<label for="ist">Condition</label>
							<select id="ist" name="status"><option value="">(none)</option>{#each data.vocab.statuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}</select>
						</div>
					</div>
					<div class="fields">
						<div><label for="ivf">Default from</label><input id="ivf" name="valid_from" placeholder="1925" /></div>
						<div><label for="ivt">Default until</label><input id="ivt" name="valid_to" /></div>
						<div>
							<label for="ic">Confidence</label>
							<select id="ic" name="confidence">{#each ['confirmed', 'probable', 'approximate', 'speculative'] as c (c)}<option selected={c === 'approximate'}>{c}</option>{/each}</select>
						</div>
						<div>
							<label for="isrc">Source</label>
							<select id="isrc" name="source_id"><option value="">(uncited)</option>{#each data.sources as s (s.id)}<option value={s.id}>{s.title}</option>{/each}</select>
						</div>
					</div>
					<button class="primary">Import {importFc.features.length} features</button>
				</form>
			{/if}
		{/if}
	</aside>

	<div class="stage">
		<div class="map" bind:this={mapEl}></div>
		<div class="top" bind:this={topEl} class:hidden={compare !== 'swipe' || !activeSource} style:clip-path="inset(0 {100 - swipe * 100}% 0 0)"></div>
		{#if compare === 'swipe' && activeSource}
			<div class="swipe" style:left="{swipe * 100}%" onpointerdown={() => (dragging = true)} role="slider" aria-valuenow={Math.round(swipe * 100)} aria-label="Swipe position" tabindex="0">
				<span>⇔</span>
			</div>
		{/if}
		{#if georef}<div class="banner">Aligning: drag the corners · lower the opacity to see streets beneath</div>{/if}
		<div class="dock">
			<YearSlider bind:year min={Math.min(data.minYear, data.settings.min_year)} max={data.maxYear} />
		</div>
	</div>
</div>

<style>
	.wb {
		display: grid;
		grid-template-columns: 330px 1fr;
		height: calc(100vh - var(--header-h));
	}
	.panel {
		overflow-y: auto;
		padding: 12px 14px 40px;
		border-right: 1px solid var(--line);
		background: var(--bg-2);
		font-size: 0.88rem;
	}
	.panel h3 {
		margin: 8px 0 4px;
		font-size: 1rem;
	}
	.tabs,
	.seg {
		display: flex;
		gap: 2px;
		margin-bottom: 10px;
	}
	.tabs button,
	.seg button {
		flex: 1;
		justify-content: center;
		padding: 6px 4px;
		font-size: 0.8rem;
		text-transform: capitalize;
	}
	.tabs button.on,
	.seg button.on {
		background: var(--rust);
		border-color: var(--rust);
		color: #fff;
	}
	.nudges {
		margin-bottom: 10px;
		gap: 4px;
	}
	.nudges button {
		padding: 4px 8px;
		font-size: 0.78rem;
	}
	.kinds {
		display: flex;
		flex-wrap: wrap;
		gap: 2px 10px;
	}
	.check {
		display: flex;
		gap: 6px;
		align-items: center;
		margin: 0;
		color: var(--ink);
	}
	.preview {
		max-height: 260px;
		overflow-y: auto;
	}
	kbd {
		font-family: var(--mono);
		font-size: 0.75rem;
		padding: 0 4px;
		border: 1px solid var(--line-2);
		border-radius: 3px;
	}
	.sw {
		display: inline-block;
		width: 10px;
		height: 10px;
		vertical-align: middle;
	}
	.sw.corner {
		background: #f2c14e;
		border-radius: 2px;
	}
	.sw.move {
		background: #8fb3c9;
		border-radius: 50%;
	}
	.stage {
		position: relative;
		min-width: 0;
	}
	.map,
	.top {
		position: absolute;
		inset: 0;
	}
	.top {
		pointer-events: none;
	}
	.top.hidden {
		display: none;
	}
	.swipe {
		position: absolute;
		top: 0;
		bottom: 0;
		width: 4px;
		margin-left: -2px;
		background: var(--amber);
		cursor: ew-resize;
		z-index: 3;
	}
	.swipe span {
		position: absolute;
		top: 45%;
		left: -14px;
		width: 32px;
		height: 32px;
		display: grid;
		place-items: center;
		background: var(--amber);
		color: #17130f;
		border-radius: 50%;
		font-weight: 700;
	}
	.banner {
		position: absolute;
		top: 10px;
		left: 50%;
		transform: translateX(-50%);
		background: rgba(242, 193, 78, 0.95);
		color: #17130f;
		padding: 4px 12px;
		border-radius: 999px;
		font-size: 0.8rem;
		font-weight: 600;
		z-index: 3;
	}
	.dock {
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		z-index: 4;
	}
	:global(.handle) {
		cursor: grab;
		box-shadow: 0 0 0 2px #17130f;
	}
	:global(.handle.corner) {
		width: 16px;
		height: 16px;
		background: #f2c14e;
		border-radius: 3px;
	}
	:global(.handle.move) {
		width: 22px;
		height: 22px;
		background: #8fb3c9;
		border-radius: 50%;
	}
	@media (max-width: 800px) {
		.wb {
			grid-template-columns: 1fr;
			grid-template-rows: 45% 1fr;
		}
	}
</style>
