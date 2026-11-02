<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import { onDestroy, onMount, untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import type { GeoJSONSource, Map as MLMap } from 'maplibre-gl';
	import { baseStyle, mapView, snapshotLayers } from '$lib/map/style';
	import { can } from '$lib/perms';
	import { yearToDate } from '$lib/time';
	import { WIKIDATA_FIELDS, type ImportOptions, type PlanAction, type PlanItem, type PreviewResult } from '$lib/importTypes';

	let { data, form } = $props();

	const MAX_SPAN = 0.12;
	let mapEl: HTMLDivElement;
	let map: MLMap | undefined;
	let ready = $state(false);

	// ---------------------------------------------------------------- area + options
	let bbox = $state<[number, number, number, number] | null>(null);
	let drawing = $state(false);
	let firstCorner: [number, number] | null = null;
	let opts = $state<ImportOptions>({
		bbox: [0, 0, 0, 0],
		ohm: { enabled: true, buildings: true, unnamedBuildings: false, streets: true, railways: true, water: true, businesses: true, places: true },
		osm: { enabled: false, businesses: true, places: true, buildings: false },
		wikidata: { enabled: true, images: false, fields: Object.fromEntries(WIKIDATA_FIELDS.map((f) => [f.id, true])) },
		wikipedia: { enabled: false },
		commons: { enabled: false, historicalOnly: true },
		geonames: { enabled: false }
	});
	const anySource = $derived(opts.ohm.enabled || opts.osm.enabled || opts.wikidata.enabled || opts.wikipedia.enabled || opts.commons.enabled || opts.geonames.enabled);
	const setFields = (on: boolean) => {
		for (const f of WIKIDATA_FIELDS) opts.wikidata.fields[f.id] = on;
	};
	const SOURCE_NAMES: Record<string, string> = { ohm: 'OHM', osm: 'OSM', wikidata: 'Wikidata', wikipedia: 'Wikipedia', commons: 'Commons', geonames: 'GeoNames' };
	const span = $derived(bbox ? Math.max(bbox[2] - bbox[0], bbox[3] - bbox[1]) : 0);
	const tooBig = $derived(span > MAX_SPAN);

	function useView() {
		if (!map) return;
		const b = map.getBounds();
		const r = (n: number) => +n.toFixed(5);
		bbox = [r(b.getWest()), r(b.getSouth()), r(b.getEast()), r(b.getNorth())];
	}

	// ---------------------------------------------------------------- preview
	let loading = $state(false);
	let fetchError = $state<string | null>(null);
	let preview = $state<PreviewResult | null>(null);
	type Edit = { include: boolean; action: PlanAction; kind: string; name: string; addShape: boolean };
	let edits = $state<Record<string, Edit>>({});
	let filterAction = $state<'all' | PlanAction>('all');
	let filterKind = $state('');
	let filterText = $state('');
	let limit = $state(150);
	let hovered = $state<string | null>(null);

	async function fetchPreview() {
		if (!bbox || tooBig) return;
		loading = true;
		fetchError = null;
		preview = null;
		try {
			const res = await fetch('/import/preview', {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: JSON.stringify({ ...opts, bbox })
			});
			if (!res.ok) throw new Error((await res.json().catch(() => null))?.message ?? `HTTP ${res.status}`);
			const p = (await res.json()) as PreviewResult;
			edits = Object.fromEntries(
				p.items.map((i) => [
					i.key,
					{ include: i.action !== 'skip', action: i.action, kind: i.candidate.kind, name: i.candidate.name, addShape: i.addShape }
				])
			);
			preview = p;
			limit = 150;
			const [w, so, e, n] = p.bbox;
			map?.fitBounds([[w, so], [e, n]], { padding: 30, duration: 500 });
		} catch (e) {
			fetchError = (e as Error).message;
		} finally {
			loading = false;
		}
	}

	const visible = $derived.by(() => {
		if (!preview) return [];
		const q = filterText.trim().toLowerCase();
		return preview.items.filter((i) => {
			const e = edits[i.key];
			if (filterAction !== 'all' && e.action !== filterAction) return false;
			if (filterKind && e.kind !== filterKind) return false;
			if (q && !`${e.name} ${i.candidate.classes.join(' ')} ${i.match?.name ?? ''}`.toLowerCase().includes(q)) return false;
			return true;
		});
	});
	const selected = $derived(preview ? preview.items.filter((i) => edits[i.key]?.include && edits[i.key].action !== 'skip') : []);
	const nCreate = $derived(selected.filter((i) => edits[i.key].action === 'create').length);
	const nMerge = $derived(selected.filter((i) => edits[i.key].action === 'merge').length);
	const counts = $derived.by(() => {
		const c = { create: 0, merge: 0, skip: 0 };
		for (const i of preview?.items ?? []) c[i.action]++;
		return c;
	});
	const kindsInPreview = $derived([...new Set((preview?.items ?? []).map((i) => i.candidate.kind))].sort());

	function setAll(v: boolean) {
		for (const i of visible) if (edits[i.key].action !== 'skip') edits[i.key].include = v;
	}

	/** The rows as approved, with the editor's tweaks applied. Sent to the server on apply. */
	const planJson = $derived.by(() => {
		if (!preview) return '';
		const items: PlanItem[] = selected.map((i) => {
			const e = edits[i.key];
			return {
				...i,
				action: e.action,
				addShape: e.addShape,
				candidate: { ...i.candidate, kind: e.kind, name: e.name.trim() || i.candidate.name }
			};
		});
		return JSON.stringify({ bbox: preview.bbox, items });
	});

	// ---------------------------------------------------------------- map
	const COLORS = { create: '#7fae6a', merge: '#e0a23a', skip: '#6b5f5a' };

	function drawBbox() {
		if (!map || !ready) return;
		const fc: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };
		if (bbox) {
			const [w, s, e, n] = bbox;
			fc.features.push({ type: 'Feature', properties: { big: tooBig }, geometry: { type: 'Polygon', coordinates: [[[w, s], [e, s], [e, n], [w, n], [w, s]]] } });
		}
		(map.getSource('bbox') as GeoJSONSource).setData(fc);
	}

	function drawPreview() {
		if (!map || !ready) return;
		const features: GeoJSON.Feature[] = [];
		for (const i of preview?.items ?? []) {
			const g = i.candidate.geometry;
			if (!g) continue;
			const e = edits[i.key];
			features.push({
				type: 'Feature',
				geometry: g,
				properties: { key: i.key, color: COLORS[e.include ? e.action : 'skip'], included: e.include && e.action !== 'skip', name: e.name }
			});
		}
		(map.getSource('preview') as GeoJSONSource).setData({ type: 'FeatureCollection', features });
	}

	let lastHover: string | null = null;
	function applyHover() {
		if (!map || !ready) return;
		if (lastHover) map.setFeatureState({ source: 'preview', id: lastHover }, { hover: false });
		if (hovered) map.setFeatureState({ source: 'preview', id: hovered }, { hover: true });
		lastHover = hovered;
	}

	function focus(i: PlanItem) {
		const g = i.candidate.geometry;
		if (!g || !map) return;
		const pts: number[][] = [];
		const walk = (c: unknown): void => {
			if (Array.isArray(c) && typeof c[0] === 'number') pts.push(c as number[]);
			else if (Array.isArray(c)) c.forEach(walk);
		};
		if ('coordinates' in g) walk(g.coordinates);
		const xs = pts.map((p) => p[0]);
		const ys = pts.map((p) => p[1]);
		map.fitBounds([[Math.min(...xs), Math.min(...ys)], [Math.max(...xs), Math.max(...ys)]], { padding: 120, maxZoom: 18, duration: 600 });
		hovered = i.key;
	}

	onMount(async () => {
		const maplibregl = (await import('maplibre-gl')).default;
		map = new maplibregl.Map({
			container: mapEl,
			style: baseStyle(data.settings),
			...mapView(data.settings),
			attributionControl: { compact: true, customAttribution: 'Previews: © OpenHistoricalMap contributors (CC0), © OpenStreetMap contributors (ODbL), Wikidata (CC0), Wikipedia & Commons (Wikimedia), GeoNames (CC BY)' }
		});
		map.addControl(new maplibregl.NavigationControl(), 'top-right');
		map.on('load', async () => {
			const m = map!;
			m.setPaintProperty('basemap', 'raster-opacity', 0.5);
			m.addSource('snapshot', { type: 'geojson', data: { type: 'FeatureCollection', features: [] }, promoteId: 'id' });
			for (const l of snapshotLayers('snapshot')) m.addLayer({ ...l, paint: { ...(l.paint ?? {}) } } as never);
			for (const id of ['snapshot-area-fill', 'snapshot-space-fill']) if (m.getLayer(id)) m.setPaintProperty(id, 'fill-opacity', 0.15);
			m.addSource('bbox', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			m.addLayer({ id: 'bbox-fill', type: 'fill', source: 'bbox', paint: { 'fill-color': ['case', ['get', 'big'], '#e0552b', '#8fb3c9'], 'fill-opacity': 0.06 } });
			m.addLayer({ id: 'bbox-line', type: 'line', source: 'bbox', paint: { 'line-color': ['case', ['get', 'big'], '#e0552b', '#8fb3c9'], 'line-width': 2, 'line-dasharray': [3, 2] } });
			m.addSource('preview', { type: 'geojson', data: { type: 'FeatureCollection', features: [] }, promoteId: 'key' });
			const hover = ['boolean', ['feature-state', 'hover'], false];
			m.addLayer({ id: 'pv-fill', type: 'fill', source: 'preview', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': ['get', 'color'], 'fill-opacity': ['case', hover, 0.8, ['get', 'included'], 0.45, 0.12] } } as never);
			m.addLayer({ id: 'pv-line', type: 'line', source: 'preview', filter: ['!=', ['geometry-type'], 'Point'], paint: { 'line-color': ['case', hover, '#f2c14e', ['get', 'color']], 'line-width': ['case', hover, 4, 2] } } as never);
			m.addLayer({ id: 'pv-pt', type: 'circle', source: 'preview', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': ['case', hover, 9, 6], 'circle-color': ['get', 'color'], 'circle-stroke-color': ['case', hover, '#f2c14e', '#17130f'], 'circle-stroke-width': 2, 'circle-opacity': ['case', ['get', 'included'], 1, 0.4] } } as never);
			m.on('click', (ev) => {
				if (drawing) {
					const c: [number, number] = [+ev.lngLat.lng.toFixed(5), +ev.lngLat.lat.toFixed(5)];
					if (!firstCorner) firstCorner = c;
					else {
						bbox = [Math.min(firstCorner[0], c[0]), Math.min(firstCorner[1], c[1]), Math.max(firstCorner[0], c[0]), Math.max(firstCorner[1], c[1])];
						firstCorner = null;
						drawing = false;
					}
					return;
				}
				const f = m.queryRenderedFeatures(ev.point, { layers: ['pv-pt', 'pv-line', 'pv-fill'] })[0];
				if (f) {
					hovered = f.properties.key;
					document.getElementById(`row-${CSS.escape(f.properties.key)}`)?.scrollIntoView({ block: 'center', behavior: 'smooth' });
				}
			});
			ready = true;
			const res = await fetch(`/api/snapshot?at=${yearToDate(new Date().getFullYear())}&ghosts=1`);
			if (res.ok) (m.getSource('snapshot') as GeoJSONSource).setData(await res.json());
		});
	});
	onDestroy(() => map?.remove());

	$effect(() => {
		void [bbox, tooBig, ready];
		untrack(drawBbox);
	});
	$effect(() => {
		void [preview, ready, JSON.stringify(edits)];
		untrack(drawPreview);
	});
	$effect(() => {
		void hovered;
		untrack(applyHover);
	});
	$effect(() => {
		if (map) map.getCanvas().style.cursor = drawing ? 'crosshair' : '';
	});

	const kindLabel = (id: string) => data.vocab.kinds.find((k) => k.id === id)?.label ?? id;
	let applying = $state(false);
	let importPrivate = $state(untrack(() => data.settings.new_pages_private));
</script>

<svelte:head><title>Import · {data.settings.site_name}</title></svelte:head>

<div class="imp">
	<aside class="panel">
		<h1>Import starter pages</h1>
		<p class="hint">
			Pull features from <a href="https://www.openhistoricalmap.org" target="_blank" rel="noopener">OpenHistoricalMap</a> and
			<a href="https://www.wikidata.org" target="_blank" rel="noopener">Wikidata</a>, OpenStreetMap, Wikipedia, Wikimedia Commons and GeoNames for an area, live. You'll see a preview of
			every page that would be created or updated; <strong>nothing is written until you apply it.</strong>
		</p>

		{#if form && 'applied' in form && form.applied}
			<p class="notice ok">
				Imported: {form.applied.created} new page{form.applied.created === 1 ? '' : 's'}{'private' in form && form.private ? ' (private until published)' : ''}, {form.applied.merged} updated.
				<a href="/changes">See recent changes →</a>
			</p>
		{/if}
		{#if form && 'undone' in form && form.undone != null}<p class="notice ok">Undone: removed {form.undone} page{form.undone === 1 ? '' : 's'}.</p>{/if}
		{#if form && 'error' in form && form.error}<p class="notice error">{form.error}</p>{/if}

		<section>
			<h2>1 · Area</h2>
			<div class="row">
				<button onclick={useView}>Use visible map area</button>
				<button class:primary={drawing} onclick={() => ((drawing = !drawing), (firstCorner = null))}>{drawing ? 'Click two corners…' : 'Draw a box'}</button>
			</div>
			{#if bbox}
				<p class="mono small muted">{bbox.join(', ')}</p>
				{#if tooBig}<p class="notice error small">Too large for one import (max ≈ {MAX_SPAN}° across). Zoom in or draw a smaller box.</p>{/if}
			{:else}
				<p class="muted small">Pan the map to a few blocks or a neighborhood, then choose the area.</p>
			{/if}
		</section>

		<section>
			<h2>2 · Sources</h2>
			<label class="check strong"><input type="checkbox" bind:checked={opts.ohm.enabled} /> OpenHistoricalMap <span class="muted small">(dated shapes, CC0)</span></label>
			{#if opts.ohm.enabled}
				<div class="sub">
					<label class="check"><input type="checkbox" bind:checked={opts.ohm.buildings} /> Buildings</label>
					<label class="check indent"><input type="checkbox" bind:checked={opts.ohm.unnamedBuildings} disabled={!opts.ohm.buildings} /> include unnamed footprints</label>
					<label class="check"><input type="checkbox" bind:checked={opts.ohm.streets} /> Streets & highways</label>
					<label class="check"><input type="checkbox" bind:checked={opts.ohm.railways} /> Railways & stations</label>
					<label class="check"><input type="checkbox" bind:checked={opts.ohm.water} /> Water</label>
					<label class="check"><input type="checkbox" bind:checked={opts.ohm.businesses} /> Shops, businesses & amenities</label>
					<label class="check"><input type="checkbox" bind:checked={opts.ohm.places} /> Neighborhoods, parks, landmarks</label>
				</div>
			{/if}
			<label class="check strong"><input type="checkbox" bind:checked={opts.osm.enabled} /> OpenStreetMap <span class="muted small">(places & businesses that exist today, ODbL)</span></label>
			{#if opts.osm.enabled}
				<div class="sub">
					<label class="check"><input type="checkbox" bind:checked={opts.osm.businesses} /> Shops, businesses & amenities</label>
					<label class="check"><input type="checkbox" bind:checked={opts.osm.places} /> Landmarks, parks, schools, worship, museums</label>
					<label class="check"><input type="checkbox" bind:checked={opts.osm.buildings} /> Named buildings</label>
					<p class="hint">Current data: no dates are added, so these pages have no end.</p>
				</div>
			{/if}
			<label class="check strong"><input type="checkbox" bind:checked={opts.wikidata.enabled} /> Wikidata <span class="muted small">(names, dates, facts, CC0)</span></label>
			{#if opts.wikidata.enabled}
				<div class="sub">
					<label class="check"><input type="checkbox" bind:checked={opts.wikidata.images} /> Link Wikimedia Commons images</label>
					<p class="hint">Images are linked, not copied; each keeps its own Commons license.</p>
					<p class="small muted">
						Facts to import:
						<button class="linkish" type="button" onclick={() => setFields(true)}>all</button> ·
						<button class="linkish" type="button" onclick={() => setFields(false)}>none</button>
					</p>
					{#each WIKIDATA_FIELDS as f (f.id)}
						<label class="check"><input type="checkbox" bind:checked={opts.wikidata.fields[f.id]} /> {f.label}</label>
					{/each}
				</div>
			{/if}
			<label class="check strong"><input type="checkbox" bind:checked={opts.wikipedia.enabled} /> Wikipedia <span class="muted small">(geotagged articles → summaries, CC BY-SA)</span></label>
			<label class="check strong"><input type="checkbox" bind:checked={opts.commons.enabled} /> Wikimedia Commons <span class="muted small">(geotagged files → media pages)</span></label>
			{#if opts.commons.enabled}
				<div class="sub">
					<label class="check"><input type="checkbox" bind:checked={opts.commons.historicalOnly} /> Only files dated 1975 or earlier</label>
					<p class="hint">Files are linked, not copied; each keeps its own license.</p>
				</div>
			{/if}
			<label class="check strong"><input type="checkbox" bind:checked={opts.geonames.enabled} disabled={!data.geonamesConfigured} /> GeoNames <span class="muted small">(place names, CC BY)</span></label>
			{#if !data.geonamesConfigured}<p class="hint">An admin can add a GeoNames username under Admin → Settings → Secrets to enable GeoNames.</p>{/if}
			<button class="primary wide" onclick={fetchPreview} disabled={!bbox || tooBig || loading || !anySource}>
				{loading ? 'Fetching & matching…' : 'Fetch preview'}
			</button>
			{#if fetchError}<p class="notice error small">{fetchError}</p>{/if}
		</section>

		{#if preview}
			<section>
				<h2>3 · Review</h2>
				<p class="small">
					{#each Object.entries(SOURCE_NAMES) as [id, label] (id)}{#if preview.counts[id as keyof typeof preview.counts]}{label} {preview.counts[id as keyof typeof preview.counts]} · {/if}{/each}combined {preview.counts.combined}
					{#if preview.counts.hiddenUnnamed}· <span class="muted">{preview.counts.hiddenUnnamed} unnamed footprints hidden</span>{/if}
				</p>
				{#each preview.warnings as w (w)}<p class="notice small">{w}</p>{/each}
				<div class="legend">
					<span><i style:background={COLORS.create}></i>new {counts.create}</span>
					<span><i style:background={COLORS.merge}></i>update {counts.merge}</span>
					<span><i style:background={COLORS.skip}></i>up to date {counts.skip}</span>
				</div>
				<p class="hint">Updates only fill gaps on existing pages (missing dates, shape, names, attributes, tags). They never overwrite.</p>
			</section>
		{/if}

		{#if data.batches.length}
			<section>
				<h2>Recent imports</h2>
				<ul class="plain-list small">
					{#each data.batches as b (b.id)}
						<li class:undone={b.undone_at}>
							<div class="spread">
								<span>{b.sources.join(' + ')} · {b.summary?.created ?? 0} new, {b.summary?.merged ?? 0} updated</span>
								{#if can('moderate') && !b.undone_at && (b.summary?.created ?? 0) > 0}
									<form
										method="post"
										action="?/undo"
										use:enhance={({ cancel }) => {
											if (!confirm(`Delete the ${b.summary?.created} page(s) this import created? Updates it made to existing pages stay (see the change log).`)) cancel();
										}}
									>
										<input type="hidden" name="batch" value={b.id} />
										<button class="danger">Undo</button>
									</form>
								{/if}
							</div>
							<div class="muted">{b.by?.display_name ?? 'someone'} · {new Date(b.created_at).toLocaleString()}{b.undone_at ? ' · undone' : ''}</div>
						</li>
					{/each}
				</ul>
			</section>
		{/if}
	</aside>

	<div class="right">
		<div class="map" bind:this={mapEl}></div>

		{#if preview}
			<div class="table">
				<div class="toolbar">
					<select bind:value={filterAction} aria-label="Filter by action">
						<option value="all">All rows ({preview.items.length})</option>
						<option value="create">New ({counts.create})</option>
						<option value="merge">Updates ({counts.merge})</option>
						<option value="skip">Up to date ({counts.skip})</option>
					</select>
					<select bind:value={filterKind} aria-label="Filter by kind">
						<option value="">all kinds</option>
						{#each kindsInPreview as k (k)}<option value={k}>{kindLabel(k)}</option>{/each}
					</select>
					<input bind:value={filterText} placeholder="Filter names…" />
					<button class="ghost" onclick={() => setAll(true)}>Select shown</button>
					<button class="ghost" onclick={() => setAll(false)}>Clear shown</button>
					<span class="spacer"></span>
					<form
						method="post"
						action="?/apply"
						use:enhance={({ cancel }) => {
							if (!selected.length) return cancel();
							if (!confirm(`Apply ${selected.length} change(s)?\n\n${nCreate} new page(s)${importPrivate ? ' (private)' : ''}\n${nMerge} update(s) to existing pages\n\nEvery fact will be cited to this import.`)) return cancel();
							applying = true;
							return async ({ result, update }) => {
								applying = false;
								await update();
								if (result.type === 'success') {
									preview = null;
									edits = {};
								}
							};
						}}
					>
						<input type="hidden" name="plan" value={planJson} />
						<label class="privcheck" title="New pages stay hidden from the public until you publish them">
							<input type="checkbox" name="private" bind:checked={importPrivate} /> new pages private
						</label>
						<button class="primary" disabled={!selected.length || applying}>
							{applying ? 'Applying…' : `Apply ${selected.length} (${nCreate} new, ${nMerge} updates)`}
						</button>
					</form>
				</div>

				<div class="rows">
					{#each visible.slice(0, limit) as i (i.key)}
						{@const e = edits[i.key]}
						<div
							class="rowi"
							class:off={!e.include || e.action === 'skip'}
							class:hl={hovered === i.key}
							id="row-{i.key}"
							role="row"
							tabindex="-1"
							onmouseenter={() => (hovered = i.key)}
						>
							<input type="checkbox" bind:checked={e.include} disabled={e.action === 'skip'} aria-label="Include {e.name}" />
							<div class="main">
								<div class="line1">
									<span class="dot" style:background={COLORS[e.action]}></span>
									{#if e.action === 'create'}
										<input class="name" bind:value={e.name} aria-label="Page name" />
										<select class="kind" bind:value={e.kind} aria-label="Kind">
											{#each data.vocab.kinds as k (k.id)}<option value={k.id}>{k.label}</option>{/each}
										</select>
									{:else}
										<strong>{e.name}</strong>
										{#if i.match}
											<span class="muted small">→ <a href="/e/{i.match.slug}" target="_blank">{i.match.name}</a> ({i.match.reason})</span>
										{/if}
									{/if}
									<span class="spacer"></span>
									<select class="act" bind:value={e.action} aria-label="Action">
										<option value="create">create new</option>
										{#if i.match}<option value="merge">update existing</option>{/if}
										<option value="skip">skip</option>
									</select>
									<button class="ghost tiny" onclick={() => focus(i)} title="Show on map" disabled={!i.candidate.geometry}>⌖</button>
								</div>
								<div class="chips">
									{#each i.changes as ch (ch)}<span class="chip">{ch}</span>{/each}
									{#if e.action === 'merge' && i.candidate.geometry && !i.addShape}
										<label class="chip opt"><input type="checkbox" bind:checked={e.addShape} /> also add this shape</label>
									{/if}
								</div>
								<div class="meta muted">
									{i.candidate.classes.slice(0, 3).join(', ')}
									{#each i.candidate.ext as x (x.source + x.id)}
										· <a href={x.url} target="_blank" rel="noopener">{x.source === 'ohm' ? 'OHM ' + x.id : (SOURCE_NAMES[x.source] ?? x.source) + ' ' + x.id}</a>
									{/each}
								</div>
							</div>
						</div>
					{:else}
						<p class="muted pad">No rows match the filters.</p>
					{/each}
					{#if visible.length > limit}
						<button class="ghost more" onclick={() => (limit += 300)}>Show {Math.min(300, visible.length - limit)} more of {visible.length - limit}</button>
					{/if}
				</div>
			</div>
		{:else if loading}
			<div class="table placeholder"><p class="muted">Querying the selected sources, then matching against existing pages…</p></div>
		{/if}
	</div>
</div>

<style>
	.imp {
		display: grid;
		grid-template-columns: 340px 1fr;
		height: calc(100vh - var(--header-h));
	}
	.panel {
		overflow-y: auto;
		padding: 14px 16px 40px;
		border-right: 1px solid var(--line);
		background: var(--bg-2);
		font-size: 0.88rem;
	}
	.panel h1 {
		font-size: 1.4rem;
	}
	.panel h2 {
		font-size: 0.95rem;
		font-family: var(--sans);
		margin: 18px 0 8px;
	}
	.check {
		display: flex;
		align-items: center;
		gap: 7px;
		margin: 4px 0;
		color: var(--ink);
		font-size: 0.86rem;
	}
	.check.strong {
		font-weight: 600;
		margin-top: 10px;
	}
	.check.indent {
		margin-left: 22px;
		color: var(--ink-2);
	}
	.linkish {
		background: none;
		border: 0;
		padding: 0;
		color: var(--link, inherit);
		text-decoration: underline;
		cursor: pointer;
		font: inherit;
	}
	.sub {
		margin-left: 22px;
	}
	.wide {
		width: 100%;
		justify-content: center;
		margin-top: 14px;
	}
	.legend {
		display: flex;
		gap: 12px;
		font-size: 0.8rem;
	}
	.legend i {
		display: inline-block;
		width: 10px;
		height: 10px;
		border-radius: 50%;
		margin-right: 4px;
	}
	li.undone {
		opacity: 0.5;
	}
	.right {
		display: grid;
		grid-template-rows: minmax(260px, 45%) 1fr;
		min-width: 0;
		min-height: 0;
	}
	.map {
		position: relative;
		min-height: 0;
	}
	.table {
		display: flex;
		flex-direction: column;
		min-height: 0;
		border-top: 1px solid var(--line);
	}
	.placeholder {
		align-items: center;
		justify-content: center;
	}
	.toolbar {
		display: flex;
		gap: 6px;
		align-items: center;
		padding: 8px 12px;
		border-bottom: 1px solid var(--line);
		background: var(--panel);
		flex-wrap: wrap;
	}
	.toolbar select,
	.toolbar input {
		width: auto;
		padding: 5px 8px;
		font-size: 0.82rem;
	}
	.spacer {
		flex: 1;
	}
	form[action='?/apply'] {
		display: flex;
		align-items: center;
		gap: 10px;
	}
	.privcheck {
		display: flex;
		align-items: center;
		gap: 5px;
		margin: 0;
		font-size: 0.8rem;
		color: var(--ink-2);
		white-space: nowrap;
	}
	.rows {
		overflow-y: auto;
		min-height: 0;
	}
	.rowi {
		display: grid;
		grid-template-columns: 24px 1fr;
		gap: 8px;
		padding: 8px 12px;
		border-bottom: 1px solid var(--line);
		font-size: 0.86rem;
	}
	.rowi.off {
		opacity: 0.5;
	}
	.rowi.hl {
		background: rgba(242, 193, 78, 0.08);
	}
	.line1 {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
	}
	.dot {
		width: 9px;
		height: 9px;
		border-radius: 50%;
		flex: none;
	}
	.name {
		width: auto;
		min-width: 220px;
		flex: 0 1 320px;
		padding: 3px 6px;
		font-size: 0.86rem;
	}
	.kind,
	.act {
		width: auto;
		padding: 3px 6px;
		font-size: 0.8rem;
	}
	.tiny {
		padding: 2px 8px;
	}
	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
		margin: 5px 0 3px;
	}
	.chip {
		font-size: 0.72rem;
		padding: 1px 7px;
		border-radius: 3px;
		background: var(--panel-2);
		color: var(--ink-2);
	}
	.chip.opt {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		margin: 0;
		background: rgba(224, 162, 58, 0.15);
		cursor: pointer;
	}
	.meta {
		font-size: 0.72rem;
	}
	.more {
		margin: 10px auto;
		display: flex;
	}
	.pad {
		padding: 16px;
	}
	@media (max-width: 900px) {
		.imp {
			grid-template-columns: 1fr;
			height: auto;
		}
		.right {
			grid-template-rows: 360px auto;
		}
	}
</style>
