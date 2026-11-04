<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import { onDestroy, onMount, untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import type { GeoJSONSource, ImageSource, Map as MLMap, Marker } from 'maplibre-gl';
	import YearSlider from '$lib/components/YearSlider.svelte';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import TemporalFields from '$lib/components/TemporalFields.svelte';
	import ScanPinView from '$lib/components/ScanPinView.svelte';
	import { apply, cornersFor, fit, fromMerc, metres, minPins, toMerc, type FitKind, type XY } from '$lib/map/georef';
	import { baseStyle, mapView, snapshotLayers } from '$lib/map/style';
	import { loadView, saveView, loadYear, saveYear } from '$lib/mapMemory';
	import { can } from '$lib/perms';
	import { yearToDate } from '$lib/time';

	let { data, form } = $props();

	type Tool = 'overlay' | 'trace' | 'area' | 'import';
	type Corners = [[number, number], [number, number], [number, number], [number, number]];

	let tool = $state<Tool>('overlay');
	let year = $state(untrack(() => loadYear() ?? data.settings.default_year));
	let ready = $state(false);
	let mapEl: HTMLDivElement;
	let topEl: HTMLDivElement;
	let map: MLMap | undefined;
	let top: MLMap | undefined;
	let maplibre: typeof import('maplibre-gl') | undefined;
	let lastSnap: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] };
	let refreshKey = $state(0);

	// ---------------------------------------------------------------- session overlay
	// Scans and tile layers are drawing aids for THIS session only. A scan is
	// read straight from the editor's disk (object URL); nothing is uploaded or
	// stored. Alignments can be exported to a small JSON file and re-loaded.
	let opacity = $state(0.7);
	let overlayHidden = $state(false); // flicker (hold F)
	let compare = $state<'blend' | 'swipe'>('blend');
	let swipe = $state(0.5);
	let scan = $state<{ name: string; url: string; corners: Corners; width: number; height: number } | null>(null);
	let tileUrl = $state('');
	let tileInput = $state('');
	let aligning = $state(true); // show corner handles
	// Phones: aligning takes the whole screen (scan and/or map) with a compact control bar;
	// "More options" brings the full panel back
	let narrow = $state(false);
	let panelOpen = $state(false);
	let depictsYear = $state(''); // year the scan shows; pre-fills traced shapes
	let markers: Marker[] = [];
	let scanError = $state<string | null>(null);

	// Two ways to align a scan: drag its four corners, or match pins (control
	// points) on the scan to the same spots on the map and fit the sheet to them.
	type Pin = { id: number; img: XY | null; map: XY | null };
	let alignMode = $state<'corners' | 'pins'>('corners');
	let pins = $state<Pin[]>([]);
	let pinSeq = $state(0);
	let fitChoice = $state<'auto' | FitKind>('auto');
	let pinMarkers: Marker[] = [];

	const activeSource = $derived.by(() => {
		if (scan) return { kind: 'image' as const, url: scan.url, corners: scan.corners };
		if (tileUrl) return { kind: 'xyz' as const, url: tileUrl };
		return null;
	});

	function addOverlayTo(m: MLMap, before?: string) {
		if (m.getLayer('overlay')) m.removeLayer('overlay');
		if (m.getSource('overlay')) m.removeSource('overlay');
		const src = activeSource;
		if (!src) return;
		if (src.kind === 'image') m.addSource('overlay', { type: 'image', url: src.url, coordinates: src.corners });
		else m.addSource('overlay', { type: 'raster', tiles: [src.url], tileSize: 256 });
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
			if (top?.getSource('overlay')) top.removeSource('overlay');
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
		if (!scan) return;
		scan.corners = c;
		(map?.getSource('overlay') as ImageSource | undefined)?.setCoordinates(c);
		(top?.getSource('overlay') as ImageSource | undefined)?.setCoordinates(c);
	}

	function placeMarkers() {
		markers.forEach((m) => m.remove());
		markers = [];
		if (!scan || !aligning || alignMode !== 'corners' || !map || !maplibre) return;
		const mk = (cls: string, title: string) => {
			const el = document.createElement('div');
			el.className = `handle ${cls}`;
			el.title = title;
			return el;
		};
		scan.corners.forEach((c, i) => {
			const m = new maplibre!.Marker({ element: mk('corner', ['top-left', 'top-right', 'bottom-right', 'bottom-left'][i]), draggable: true })
				.setLngLat(c)
				.addTo(map!);
			m.on('drag', () => {
				const ll = m.getLngLat();
				const next = scan!.corners.map((x) => [...x]) as Corners;
				next[i] = [ll.lng, ll.lat];
				setCorners(next);
				markers[4]?.setLngLat(centroid(next));
			});
			markers.push(m);
		});
		const centre = new maplibre.Marker({ element: mk('move', 'Drag to move the whole sheet'), draggable: true })
			.setLngLat(centroid(scan.corners))
			.addTo(map);
		let last = centre.getLngLat();
		centre.on('dragstart', () => (last = centre.getLngLat()));
		centre.on('drag', () => {
			const ll = centre.getLngLat();
			const dx = ll.lng - last.lng;
			const dy = ll.lat - last.lat;
			last = ll;
			const next = scan!.corners.map(([x, y]) => [x + dx, y + dy]) as Corners;
			setCorners(next);
			next.forEach((c, i) => markers[i].setLngLat(c));
		});
		markers.push(centre);
	}
	const centroid = (c: Corners): [number, number] => [c.reduce((a, p) => a + p[0], 0) / 4, c.reduce((a, p) => a + p[1], 0) / 4];

	/** Rotate / scale the sheet about its centre (fine adjustments). */
	function transform(rotateDeg: number, scale: number) {
		if (!scan || !map) return;
		const c = map.project(centroid(scan.corners));
		const a = (rotateDeg * Math.PI) / 180;
		const next = scan.corners.map((ll) => {
			const p = map!.project(ll);
			const x = (p.x - c.x) * scale;
			const y = (p.y - c.y) * scale;
			const r = map!.unproject([c.x + x * Math.cos(a) - y * Math.sin(a), c.y + x * Math.sin(a) + y * Math.cos(a)]);
			return [r.lng, r.lat];
		}) as Corners;
		setCorners(next);
		placeMarkers();
	}

	async function openScan(e: Event) {
		const file = (e.currentTarget as HTMLInputElement).files?.[0];
		if (!file || !map) return;
		scanError = null;
		try {
			if (scan) URL.revokeObjectURL(scan.url);
			const url = URL.createObjectURL(file);
			const img = new Image();
			img.src = url;
			await img.decode();
			// Start at ~60% of the view, preserving the scan's aspect ratio on screen
			const { clientWidth: W, clientHeight: H } = map.getContainer();
			const w = Math.min(W * 0.6, (H * 0.6 * img.width) / img.height);
			const h = (w * img.height) / img.width;
			const x0 = (W - w) / 2;
			const y0 = (H - h) / 2;
			const ll = (x: number, y: number): [number, number] => {
				const p = map!.unproject([x, y]);
				return [p.lng, p.lat];
			};
			tileUrl = '';
			aligning = true;
			panelOpen = false;
			clearPins();
			scan = {
				name: file.name,
				url,
				width: img.width,
				height: img.height,
				corners: [ll(x0, y0), ll(x0 + w, y0), ll(x0 + w, y0 + h), ll(x0, y0 + h)]
			};
			const y = file.name.match(/(1[89]\d\d|20\d\d)/);
			if (y) {
				depictsYear = y[1];
				year = Number(y[1]);
			}
		} catch (err) {
			scanError = `Couldn't open that image: ${(err as Error).message}`;
		}
	}

	function closeScan() {
		if (scan) URL.revokeObjectURL(scan.url);
		scan = null;
		markers.forEach((m) => m.remove());
		markers = [];
		clearPins();
	}

	// ---------------------------------------------------------------- pin alignment
	const pinning = $derived(tool === 'overlay' && !!scan && aligning && alignMode === 'pins');
	const pairs = $derived(pins.filter((p) => p.img && p.map));
	const fitKind = $derived<FitKind>(fitChoice === 'auto' ? (pairs.length >= 3 ? 'affine' : 'similarity') : fitChoice);
	const pinFit = $derived(
		pairs.length >= minPins(fitKind)
			? fit(
					pairs.map((p) => p.img!),
					pairs.map((p) => toMerc(p.map!)),
					fitKind
				)
			: null
	);
	/**
	 * How far (metres) each pin's scan spot lands from its map spot under the current fit.
	 * Only meaningful once there are more pins than the fit needs (otherwise every pin is matched exactly).
	 */
	const residuals = $derived(
		new Map<number, number>(
			pinFit && pairs.length > minPins(pinFit.kind) ? pairs.map((p) => [p.id, metres(fromMerc(apply(pinFit.m, p.img!)), p.map!)]) : []
		)
	);
	const rms = $derived(residuals.size ? Math.sqrt([...residuals.values()].reduce((s, r) => s + r * r, 0) / residuals.size) : null);
	const waitingImg = $derived(pins.find((p) => !p.img)?.id ?? null);
	const waitingMap = $derived(pins.find((p) => !p.map)?.id ?? null);
	/** Where the next tap goes while pinning: a pin's scan spot, or its map spot. */
	const pinStep = $derived.by((): { where: 'scan' | 'map'; id: number } => {
		if (waitingMap != null && pins.find((p) => p.id === waitingMap)?.img) return { where: 'map', id: waitingMap };
		if (waitingImg != null) return { where: 'scan', id: waitingImg };
		return { where: 'scan', id: pinSeq + 1 };
	});

	function addImgPin(img: XY) {
		const p = pins.find((x) => !x.img);
		if (p) p.img = img;
		else pins.push({ id: ++pinSeq, img, map: null });
	}
	function addMapPin(ll: XY) {
		const p = pins.find((x) => !x.map);
		if (p) p.map = ll;
		else pins.push({ id: ++pinSeq, img: null, map: ll });
	}
	function moveImgPin(id: number, img: XY) {
		const p = pins.find((x) => x.id === id);
		if (p) p.img = img;
	}
	function removePin(id: number) {
		pins = pins.filter((p) => p.id !== id);
		if (!pins.length) pinSeq = 0;
	}
	function clearPins() {
		pins = [];
		pinSeq = 0;
	}

	function placePins() {
		pinMarkers.forEach((m) => m.remove());
		pinMarkers = [];
		if (!pinning || !map || !maplibre) return;
		for (const p of pins) {
			if (!p.map) continue;
			const el = document.createElement('div');
			el.className = `handle pin${p.img ? '' : ' half'}`;
			el.textContent = String(p.id);
			el.title = `Pin ${p.id}: drag to adjust`;
			const id = p.id;
			const m = new maplibre.Marker({ element: el, draggable: true }).setLngLat(p.map).addTo(map);
			m.on('drag', () => {
				const ll = m.getLngLat();
				const q = pins.find((x) => x.id === id);
				if (q) q.map = [+ll.lng.toFixed(7), +ll.lat.toFixed(7)];
			});
			pinMarkers.push(m);
		}
	}

	/** Save the alignment to a small file so the same scan can be re-aligned instantly next time. */
	function exportAlignment() {
		if (!scan) return;
		const blob = new Blob(
			[
				JSON.stringify(
					{
						decaynet_alignment: 1,
						file: scan.name,
						width: scan.width,
						height: scan.height,
						depicts: depictsYear || null,
						corners: scan.corners,
						pins: pairs.map((p) => ({ image: p.img, map: p.map }))
					},
					null,
					2
				)
			],
			{ type: 'application/json' }
		);
		const a = document.createElement('a');
		a.href = URL.createObjectURL(blob);
		a.download = `${scan.name.replace(/\.[^.]+$/, '')}.alignment.json`;
		a.click();
		URL.revokeObjectURL(a.href);
	}

	async function importAlignment(e: Event) {
		const file = (e.currentTarget as HTMLInputElement).files?.[0];
		if (!file || !scan) return;
		try {
			const j = JSON.parse(await file.text());
			if (!Array.isArray(j.corners) || j.corners.length !== 4) throw new Error('No corners in that file.');
			setCorners(j.corners as Corners);
			if (j.depicts) depictsYear = String(j.depicts);
			// Pins saved with the alignment come back too, so you can keep refining
			const ok = (v: unknown): v is XY => Array.isArray(v) && v.length === 2 && v.every((n) => typeof n === 'number');
			if (Array.isArray(j.pins)) {
				const loaded = (j.pins as { image?: unknown; map?: unknown }[]).filter((p) => ok(p?.image) && ok(p?.map));
				pins = loaded.map((p, i) => ({ id: i + 1, img: p.image as XY, map: p.map as XY }));
				pinSeq = pins.length;
			}
			placeMarkers();
			const xs = j.corners.map((c: number[]) => c[0]);
			const ys = j.corners.map((c: number[]) => c[1]);
			map?.fitBounds([[Math.min(...xs), Math.min(...ys)], [Math.max(...xs), Math.max(...ys)]], { padding: 40 });
		} catch (err) {
			scanError = (err as Error).message;
		}
	}

	function useTiles() {
		const u = tileInput.trim();
		if (!/^https:\/\/.+\{z\}.+\{x\}.+\{y\}/.test(u)) {
			scanError = 'Tile URLs look like https://…/{z}/{x}/{y}.png';
			return;
		}
		closeScan();
		scanError = null;
		tileUrl = u;
	}

	// ---------------------------------------------------------------- drawing (trace + area)
	let drawMode = $state<'polygon' | 'line' | 'point'>('polygon');
	let pts = $state<[number, number][]>([]);
	const drawing = $derived(tool === 'trace' || tool === 'area');
	const effectiveMode = $derived(tool === 'area' ? 'polygon' : drawMode);
	const geometry = $derived.by((): GeoJSON.Geometry | null => {
		if (effectiveMode === 'point') return pts.length ? { type: 'Point', coordinates: pts[pts.length - 1] } : null;
		if (effectiveMode === 'line') return pts.length >= 2 ? { type: 'LineString', coordinates: pts } : null;
		return pts.length >= 3 ? { type: 'Polygon', coordinates: [[...pts, pts[0]]] } : null;
	});
	const geojsonText = $derived(geometry ? JSON.stringify(geometry) : '');

	// ---------------------------------------------------------------- export (no page needed)
	// Drawn shapes can be downloaded or copied as GeoJSON instead of being saved to a page.
	let traceName = $state('');
	let traceKind = $state('building');
	let traceRole = $state('footprint');
	let kept = $state<GeoJSON.Feature[]>([]);
	let exportNote = $state<string | null>(null);
	let noteTimer: ReturnType<typeof setTimeout> | undefined;

	function currentFeature(): GeoJSON.Feature | null {
		if (!geometry) return null;
		const props: Record<string, string | number> = { kind: traceKind, role: traceRole };
		if (traceName.trim()) props.name = traceName.trim();
		const y = /^\d{4}$/.test(depictsYear) ? Number(depictsYear) : year;
		props.year = y;
		if (scan) props.traced_from = scan.name;
		return { type: 'Feature', geometry: $state.snapshot(geometry) as GeoJSON.Geometry, properties: props };
	}
	const fc = (features: GeoJSON.Feature[]): GeoJSON.FeatureCollection => ({ type: 'FeatureCollection', features });
	const exportText = (features: GeoJSON.Feature[]) => JSON.stringify(fc(features), null, 2);

	function note(msg: string) {
		exportNote = msg;
		clearTimeout(noteTimer);
		noteTimer = setTimeout(() => (exportNote = null), 2500);
	}

	function download(features: GeoJSON.Feature[]) {
		if (!features.length) return;
		const base = (features.length === 1 && (features[0].properties?.name as string | undefined)) || `traced-${features.length === 1 ? 'shape' : 'shapes'}`;
		const a = document.createElement('a');
		a.href = URL.createObjectURL(new Blob([exportText(features)], { type: 'application/geo+json' }));
		a.download = `${base.replace(/[^\w.-]+/g, '-').replace(/^-+|-+$/g, '') || 'shape'}.geojson`;
		a.click();
		URL.revokeObjectURL(a.href);
		note(`Downloaded ${a.download}`);
	}

	async function copy(features: GeoJSON.Feature[]) {
		if (!features.length) return;
		const text = exportText(features);
		try {
			await navigator.clipboard.writeText(text);
		} catch {
			// Clipboard API needs a secure context; fall back to the old way
			const ta = document.createElement('textarea');
			ta.value = text;
			ta.style.position = 'fixed';
			ta.style.opacity = '0';
			document.body.appendChild(ta);
			ta.select();
			const ok = document.execCommand('copy');
			ta.remove();
			if (!ok) return note("Couldn't reach the clipboard; use Download instead.");
		}
		note(`Copied ${features.length} shape${features.length === 1 ? '' : 's'} as GeoJSON`);
	}

	/** Set the current shape aside for a multi-shape export and start a new one. */
	function keepShape() {
		const f = currentFeature();
		if (!f) return;
		kept.push(f);
		pts = [];
		traceName = '';
	}
	function drawKept() {
		if (!map || !ready) return;
		(map.getSource('kept') as GeoJSONSource | undefined)?.setData(fc($state.snapshot(kept) as GeoJSON.Feature[]));
	}

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

	// How strongly the shape being drawn shows over the scan
	let shapeFill = $state(0.25);
	let shapeLine = $state(1);
	function applyShapeOpacity() {
		if (!map || !ready) return;
		map.setPaintProperty('draft-fill', 'fill-opacity', shapeFill);
		map.setPaintProperty('draft-line', 'line-opacity', shapeLine);
		map.setPaintProperty('draft-pt', 'circle-opacity', shapeLine);
		map.setPaintProperty('draft-pt', 'circle-stroke-opacity', shapeLine);
	}

	// Drag handle that moves the whole shape being drawn
	let shapeHandle: Marker | undefined;
	let movingShape = false;
	const ptsCentre = (p: [number, number][]): [number, number] => [p.reduce((a, c) => a + c[0], 0) / p.length, p.reduce((a, c) => a + c[1], 0) / p.length];
	function syncShapeHandle() {
		if (!map || !maplibre || !ready) return;
		if (!drawing || !pts.length) {
			shapeHandle?.remove();
			shapeHandle = undefined;
			return;
		}
		if (shapeHandle) {
			if (!movingShape) shapeHandle.setLngLat(ptsCentre(pts));
			return;
		}
		const el = document.createElement('div');
		el.className = 'handle move';
		el.title = 'Drag to move the whole shape';
		const h = new maplibre.Marker({ element: el, draggable: true }).setLngLat(ptsCentre(pts)).addTo(map);
		let start = h.getLngLat();
		let startPts = pts;
		h.on('dragstart', () => {
			movingShape = true;
			start = h.getLngLat();
			startPts = pts;
		});
		h.on('drag', () => {
			const ll = h.getLngLat();
			const dx = ll.lng - start.lng;
			const dy = ll.lat - start.lat;
			pts = startPts.map(([x, y]) => [+(x + dx).toFixed(7), +(y + dy).toFixed(7)]);
		});
		h.on('dragend', () => {
			movingShape = false;
			h.setLngLat(ptsCentre(pts));
		});
		shapeHandle = h;
	}

	// ---------------------------------------------------------------- area preview
	let previewIds = $state<string[]>([]);

	// ---------------------------------------------------------------- bulk selection
	// Shift-click a building to select it (Shift-drag selects a box); on a phone, the map's
	// Select button turns taps into selection. The selected pages can then be marked gone by a
	// year, or still standing in one, in one go.
	interface Picked {
		id: string;
		name: string;
		slug: string;
		kind: string;
		status: string | null;
		ghost: boolean;
	}
	let selected = $state<Picked[]>([]);
	let selecting = $state(false);
	let boxMode = $state(false);
	let box = $state<{ x0: number; y0: number; x1: number; y1: number } | null>(null);
	let bulkResult = $state<{
		action: 'gone' | 'condition' | 'standing';
		at: string;
		status?: string;
		done: number;
		skipped: { id: string; name: string; slug: string; reason: string }[];
	} | null>(null);
	/** what the selection gets: gone by a year, a condition from a year, or still standing in a year */
	let bulkMode = $state<'gone' | 'condition' | 'standing'>('gone');
	let bulkCondition = $state('abandoned');
	let bulkBusy = $state(false);
	let bulkYearInput = $state<string | null>(null);
	let bulkNoteInput = $state<string | null>(null);
	const bulkYear = $derived(bulkYearInput ?? (/^\d{4}$/.test(depictsYear) ? depictsYear : String(year)));
	const goneStatuses = $derived(data.vocab.statuses.filter((st) => !st.is_extant && st.decay_level >= 5));
	// conditions of something still standing (Abandoned, Vacant, Ruin, Active again…)
	const standingStatuses = $derived(data.vocab.statuses.filter((st) => st.is_extant));
	const statusLabel = (id: string | undefined) => data.vocab.statuses.find((st) => st.id === id)?.label ?? id ?? '';
	const bulkNote = $derived(
		bulkNoteInput ?? (bulkMode === 'condition' ? `${statusLabel(bulkCondition)} in the ${bulkYear} aerial` : `Not seen in the ${bulkYear} aerial`)
	);

	const pickedOf = (f: { properties: Record<string, unknown> | null }): Picked | null => {
		const p = f.properties ?? {};
		if (!p.id) return null;
		return { id: String(p.id), name: String(p.name ?? 'Unnamed'), slug: String(p.slug ?? ''), kind: String(p.kind ?? ''), status: (p.status_label as string) ?? null, ghost: !!p.ghost };
	};
	function snapshotHits(a: [number, number], b: [number, number]): Picked[] {
		if (!map) return [];
		const layers = snapshotLayers('snapshot').map((l) => l.id).filter((id) => map!.getLayer(id));
		const seen = new Set<string>();
		const out: Picked[] = [];
		for (const f of map.queryRenderedFeatures([a, b], { layers })) {
			const p = pickedOf(f as unknown as { properties: Record<string, unknown> });
			if (p && !seen.has(p.id)) {
				seen.add(p.id);
				out.push(p);
			}
		}
		return out;
	}
	/** Click/tap: toggle the building under the pointer. */
	function pickAt(x: number, y: number) {
		const hit = snapshotHits([x - 5, y - 5], [x + 5, y + 5])[0];
		if (!hit) return;
		bulkResult = null;
		selected = selected.some((s) => s.id === hit.id) ? selected.filter((s) => s.id !== hit.id) : [...selected, hit];
	}
	/** Box: add everything inside it. */
	function pickBox(b: { x0: number; y0: number; x1: number; y1: number }) {
		const hits = snapshotHits([Math.min(b.x0, b.x1), Math.min(b.y0, b.y1)], [Math.max(b.x0, b.x1), Math.max(b.y0, b.y1)]);
		const have = new Set(selected.map((s) => s.id));
		bulkResult = null;
		selected = [...selected, ...hits.filter((h) => !have.has(h.id))];
	}
	function stopSelecting() {
		selecting = false;
		boxMode = false;
	}
	/** After a bulk action: show what happened, reload the map, start a fresh selection. */
	function afterBulk() {
		bulkBusy = true;
		return async ({ result, update }: { result: { type: string; data?: Record<string, unknown> }; update: (o?: { reset?: boolean }) => Promise<void> }) => {
			await update({ reset: false });
			bulkBusy = false;
			if (result.type === 'success' && result.data?.bulk) {
				bulkResult = result.data.bulk as typeof bulkResult;
				const skippedIds = new Set(bulkResult!.skipped.map((x) => x.id));
				// keep the ones that were skipped selected, so they can be looked at
				selected = selected.filter((x) => skippedIds.has(x.id));
				// the year and note stay: the next buildings missing from the same aerial get the same
				refreshKey++;
			}
		};
	}
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
	let resizeObs: ResizeObserver | undefined;
	async function refresh() {
		if (!map || !ready) return;
		const res = await fetch(`/api/snapshot?at=${yearToDate(year)}&ghosts=1&_=${refreshKey}`);
		if (!res.ok) return;
		lastSnap = await res.json();
		(map.getSource('snapshot') as GeoJSONSource).setData(lastSnap);
		highlight(highlightIds);
	}

	onMount(() => {
		const mq = window.matchMedia('(max-width: 800px)');
		narrow = mq.matches;
		const onChange = (e: MediaQueryListEvent) => (narrow = e.matches);
		mq.addEventListener('change', onChange);
		return () => mq.removeEventListener('change', onChange);
	});

	onMount(async () => {
		maplibre = ((await import('maplibre-gl')) as unknown as { default: typeof import('maplibre-gl') }).default;
		map = new maplibre.Map({
			container: mapEl,
			style: baseStyle(data.settings),
			...mapView(data.settings),
			...loadView(),
			attributionControl: {
				compact: true,
				customAttribution: `<a href="${data.settings.source_code_url}" target="_blank" rel="noopener">Source (AGPL)</a>`
			},
			maxZoom: 21
		});
		const mm = map;
		// The map shares the stage with the scan pane while pinning, so follow its size
		let lastW = 0;
		let lastH = 0;
		let lastLayout = '';
		resizeObs = new ResizeObserver(() => {
			const w = mapEl.clientWidth;
			const h = mapEl.clientHeight;
			const layout = `${focus}|${selectFocus}|${pinning}`;
			map?.resize();
			top?.resize();
			// Only the bottom bar grew or shrank (same layout, same width): resizing keeps the centre,
			// which would shift everything on screen by half the change; keep it where it was
			if (map && lastH && layout === lastLayout && w === lastW && h !== lastH) map.panBy([0, -(lastH - h) / 2], { duration: 0 });
			lastW = w;
			lastH = h;
			lastLayout = layout;
		});
		resizeObs.observe(mapEl);
		mm.addControl(new maplibre.NavigationControl(), 'top-right');
		mm.doubleClickZoom.disable();
		// Shift-drag selects a box of buildings here (instead of zooming to it); so does a drag in Box mode
		mm.boxZoom.disable();
		const box0 = (e: PointerEvent) => {
			if (!(e.shiftKey || boxMode) || e.button !== 0) return;
			if ((e.target as HTMLElement).closest('.maplibregl-marker, .maplibregl-ctrl')) return;
			const r = mapEl.getBoundingClientRect();
			mm.dragPan.disable();
			box = { x0: e.clientX - r.left, y0: e.clientY - r.top, x1: e.clientX - r.left, y1: e.clientY - r.top };
			const moveBox = (ev: PointerEvent) => {
				if (box) box = { ...box, x1: ev.clientX - r.left, y1: ev.clientY - r.top };
			};
			const endBox = () => {
				window.removeEventListener('pointermove', moveBox);
				window.removeEventListener('pointerup', endBox);
				window.removeEventListener('pointercancel', endBox);
				mm.dragPan.enable();
				const b = box;
				box = null;
				// a box, not a click (the click handler takes those)
				if (b && Math.hypot(b.x1 - b.x0, b.y1 - b.y0) > 6) pickBox(b);
			};
			window.addEventListener('pointermove', moveBox);
			window.addEventListener('pointerup', endBox);
			window.addEventListener('pointercancel', endBox);
		};
		mapEl.addEventListener('pointerdown', box0, true);
		mm.on('load', () => {
			const m = map!;
			m.setPaintProperty('basemap', 'raster-opacity', 0.45);
			m.addSource('snapshot', { type: 'geojson', data: { type: 'FeatureCollection', features: [] }, promoteId: 'id' });
			for (const l of snapshotLayers('snapshot')) m.addLayer(l);
			m.addSource('import', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			m.addLayer({ id: 'import-fill', type: 'fill', source: 'import', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#8fb3c9', 'fill-opacity': 0.3 } });
			m.addLayer({ id: 'import-line', type: 'line', source: 'import', paint: { 'line-color': '#8fb3c9', 'line-width': 1.5 } });
			m.addLayer({ id: 'import-pt', type: 'circle', source: 'import', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 4, 'circle-color': '#8fb3c9' } });
			m.addSource('kept', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			m.addLayer({ id: 'kept-fill', type: 'fill', source: 'kept', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#e08a4a', 'fill-opacity': 0.15 } });
			m.addLayer({ id: 'kept-line', type: 'line', source: 'kept', filter: ['!=', ['geometry-type'], 'Point'], paint: { 'line-color': '#e08a4a', 'line-width': 2, 'line-dasharray': [2, 1.5] } });
			m.addLayer({ id: 'kept-pt', type: 'circle', source: 'kept', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 5, 'circle-color': '#e08a4a', 'circle-stroke-color': '#17130f', 'circle-stroke-width': 1.5 } });
			m.addSource('draft', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			m.addLayer({ id: 'draft-fill', type: 'fill', source: 'draft', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#f2c14e', 'fill-opacity': 0.25 } });
			m.addLayer({ id: 'draft-line', type: 'line', source: 'draft', filter: ['!=', ['geometry-type'], 'Point'], paint: { 'line-color': '#f2c14e', 'line-width': 2.5 } });
			m.addLayer({ id: 'draft-pt', type: 'circle', source: 'draft', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 4.5, 'circle-color': '#f2c14e', 'circle-stroke-color': '#17130f', 'circle-stroke-width': 1.5 } });

			m.on('click', (e) => {
				// Shift-click (or a tap in Select mode) picks buildings for bulk edits
				if (e.originalEvent.shiftKey || selecting) {
					if ((e.originalEvent.target as HTMLElement | null)?.closest('.maplibregl-marker')) return;
					pickAt(e.point.x, e.point.y);
					return;
				}
				if (!drawing && !pinning) return;
				// clicking a handle isn't a new vertex
				if ((e.originalEvent.target as HTMLElement | null)?.closest('.maplibregl-marker')) return;
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
				if (pinning) addMapPin(c);
				else pts = effectiveMode === 'point' ? [c] : [...pts, c];
			});
			m.on('moveend', () => saveView({ center: [m.getCenter().lng, m.getCenter().lat], zoom: m.getZoom() }));
			m.on('move', () => top?.jumpTo({ center: m.getCenter(), zoom: m.getZoom(), bearing: m.getBearing(), pitch: m.getPitch() }));
			ready = true;
			applyOverlay();
			refresh();
		});
	});

	onDestroy(() => {
		clearTimeout(fetchTimer);
		clearTimeout(noteTimer);
		markers.forEach((m) => m.remove());
		pinMarkers.forEach((m) => m.remove());
		resizeObs?.disconnect();
		shapeHandle?.remove();
		if (scan) URL.revokeObjectURL(scan.url);
		top?.remove();
		map?.remove();
	});

	$effect(() => {
		saveYear(year);
		void [year, refreshKey];
		if (!ready) return;
		clearTimeout(fetchTimer);
		fetchTimer = setTimeout(refresh, 100);
	});
	$effect(() => {
		void [activeSource?.url, compare];
		if (!ready) return;
		if (compare === 'swipe') ensureTop();
		untrack(applyOverlay);
	});
	$effect(() => {
		void [opacity, overlayHidden];
		untrack(applyOpacity);
	});
	$effect(() => {
		void [scan?.url, aligning, alignMode, ready];
		untrack(placeMarkers);
	});
	// Rebuild map pins when pins are added, removed or completed (not while one is dragged)
	$effect(() => {
		void [pinning, ready, pins.map((p) => `${p.id}:${p.map ? 1 : 0}:${p.img ? 1 : 0}`).join()];
		untrack(placePins);
	});
	// Re-fit the sheet whenever the matched pins change
	$effect(() => {
		const f = pinFit;
		if (!f) return;
		untrack(() => scan && setCorners(cornersFor(f, scan.width, scan.height)));
	});
	// Hide handles while drawing so clicks land on the map
	$effect(() => {
		if (tool === 'trace' || tool === 'area') aligning = false;
	});
	$effect(() => {
		void [geometry, pts.length];
		untrack(drawDraft);
	});
	$effect(() => {
		void [kept.length, ready];
		untrack(drawKept);
	});
	$effect(() => {
		void [pts, drawing, ready];
		untrack(syncShapeHandle);
	});
	$effect(() => {
		void [shapeFill, shapeLine, ready];
		untrack(applyShapeOpacity);
	});
	// the area preview and the bulk selection share the map's "selected" look
	const highlightIds = $derived([...new Set([...previewIds, ...selected.map((x) => x.id)])]);
	$effect(() => {
		const ids = highlightIds;
		untrack(() => highlight(ids));
	});
	$effect(() => {
		if (map) map.getCanvas().style.cursor = drawing || pinning || boxMode ? 'crosshair' : selecting ? 'pointer' : '';
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
		else if (e.key === 'Escape' && (selected.length || selecting) && !(e.target as HTMLElement).closest('input, select, textarea')) {
			selected = [];
			stopSelecting();
		}
		if (pinning && e.key === 'Backspace' && pins.length) {
			e.preventDefault();
			removePin(pins[pins.length - 1].id);
		}
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
		{ id: 'overlay', label: 'Scan', ok: true },
		{ id: 'trace', label: 'Trace', ok: can('edit_content') },
		{ id: 'area', label: 'Area change', ok: can('bulk_edit') },
		{ id: 'import', label: 'Import', ok: can('bulk_edit') }
	]);
	const msg = $derived(form && form.tool === tool ? form : null);
	// on a phone, selecting takes the screen like aligning does (the bar holds the bulk actions)
	const selectFocus = $derived(narrow && (selecting || selected.length > 0));
	const focus = $derived(!selectFocus && narrow && tool === 'overlay' && !!scan && aligning && !panelOpen);
	const spatialKinds = $derived(data.vocab.kinds.filter((k) => !['person', 'organization', 'event', 'media'].includes(k.id)));
</script>

<svelte:window onkeydown={onkey} onkeyup={onkeyup} onpointermove={swipeMove} onpointerup={() => (dragging = false)} />
<svelte:head><title>Workbench · {data.settings.site_name}</title></svelte:head>

<div class="wb" class:focus={focus || selectFocus}>
	<aside class="panel">
		<div class="tabs">
			{#each TOOLS.filter((t) => t.ok) as t (t.id)}
				<button class:on={tool === t.id} onclick={() => ((tool = t.id), (pts = []))}>{t.label}</button>
			{/each}
		</div>

		{#if !narrow && (selected.length || selecting || bulkResult)}
			<section class="selection card">{@render selectionUI()}</section>
		{/if}

		{#if msg && 'error' in msg && msg.error}<p class="notice error small">{msg.error}</p>{/if}
		{#if msg && 'ok' in msg && msg.ok}
			<p class="notice ok small">{msg.ok} {#if 'slug' in msg && msg.slug}<a href="/e/{msg.slug}">Open page →</a>{/if}</p>
		{/if}

		<!-- ======================= SCAN (session only) ======================= -->
		{#if tool === 'overlay'}
			<p class="hint">
				Lay a Sanborn sheet, plat, aerial or any scanned map over the data to line things up and trace from it.
				<strong>Scans stay in your browser for this session only</strong>: nothing is uploaded or published.
			</p>
			{#if scanError}<p class="notice error small">{scanError}</p>{/if}

			{#if !scan && !tileUrl}
				<h3>Open a scan</h3>
				<input type="file" accept="image/png,image/jpeg,image/webp,image/gif" onchange={openScan} />
				<p class="hint">It appears with four corner handles. Drag each corner onto the matching intersection.</p>
				<h3>…or a tile layer</h3>
				<p class="hint">Already georeferenced in Map Warper, Allmaps or similar? Paste its XYZ URL.</p>
				<div class="row">
					<input bind:value={tileInput} placeholder={'https://…/{z}/{x}/{y}.png'} style="flex: 1" />
					<button onclick={useTiles}>Use</button>
				</div>
			{:else}
				<div class="loaded">
					<strong>{scan ? scan.name : 'Tile layer'}</strong>
					<button class="ghost" onclick={() => { closeScan(); tileUrl = ''; }}>Close</button>
				</div>
				<div class="field">
					<label for="op">Opacity {Math.round(opacity * 100)}%</label>
					<input id="op" type="range" min="0" max="1" step="0.05" bind:value={opacity} disabled={compare === 'swipe'} />
				</div>
				<div class="seg">
					<button class:on={compare === 'blend'} onclick={() => (compare = 'blend')}>Blend</button>
					<button class:on={compare === 'swipe'} onclick={() => (compare = 'swipe')}>Swipe</button>
				</div>
				<p class="hint">Hold <kbd>F</kbd> to flicker the scan off and back on.</p>
				<div class="field">
					<label for="dy">Scan shows the year</label>
					<input id="dy" bind:value={depictsYear} placeholder="1925" oninput={() => /^\d{4}$/.test(depictsYear) && (year = Number(depictsYear))} />
					<p class="hint">Moves the time slider and pre-fills dates on traced shapes.</p>
				</div>

				{#if scan}
					<hr />
					<div class="spread">
						<h3>Alignment</h3>
						<label class="check"><input type="checkbox" bind:checked={aligning} /> show handles</label>
					</div>
					{#if aligning}
						<div class="seg">
							<button class:on={alignMode === 'corners'} onclick={() => (alignMode = 'corners')} title="Drag the sheet's corners into place">Drag corners</button>
							<button class:on={alignMode === 'pins'} onclick={() => (alignMode = 'pins')} title="Pin matching spots on the scan and the map">Match pins</button>
						</div>
						{#if alignMode === 'corners'}
							<p class="hint">Drag the <span class="sw corner"></span> corners onto matching intersections; drag <span class="sw move"></span> to move the sheet. Lower the opacity to see streets beneath.</p>
							<div class="row nudges">
								<button title="Rotate left" onclick={() => transform(-1, 1)}>⟲ 1°</button>
								<button title="Rotate right" onclick={() => transform(1, 1)}>⟳ 1°</button>
								<button title="Rotate left a little" onclick={() => transform(-0.2, 1)}>⟲ .2°</button>
								<button title="Rotate right a little" onclick={() => transform(0.2, 1)}>⟳ .2°</button>
								<button title="Shrink" onclick={() => transform(0, 0.98)}>− 2%</button>
								<button title="Grow" onclick={() => transform(0, 1.02)}>+ 2%</button>
							</div>
						{:else}
							<p class="hint">
								Click a recognisable spot on the scan (a street corner, a church, a bridge), then click the same spot on the map.
								Map clicks snap to existing shapes. With <strong>2 pins</strong> the sheet moves, turns and scales into place;
								<strong>3 or more</strong> also correct stretch and skew. Spread them out toward the edges of the sheet. Drag any pin to fine-tune.
							</p>
							<p class="next">
								{#if waitingMap != null && pins.find((p) => p.id === waitingMap)?.img}
									<span class="sw pin"></span> Pin {waitingMap}: now click the same spot on the <strong>map</strong>.
								{:else if waitingImg != null}
									<span class="sw pin"></span> Pin {waitingImg}: now click that spot on the <strong>scan</strong>.
								{:else}
									<span class="sw pin"></span> Click a spot on the <strong>scan</strong> to place pin {pinSeq + 1}.
								{/if}
							</p>
							{#if pins.length}
								<table class="pins">
									<thead><tr><th>#</th><th>Scan</th><th>Map</th><th title="Distance between where the fitted scan puts this spot and where you pinned it">Off by</th><th></th></tr></thead>
									<tbody>
										{#each pins as p (p.id)}
											<tr>
												<td><span class="pin-no">{p.id}</span></td>
												<td>{p.img ? '✓' : '—'}</td>
												<td>{p.map ? '✓' : '—'}</td>
												<td class:bad={(residuals.get(p.id) ?? 0) > 2 * (rms ?? Infinity)}>
													{#if residuals.has(p.id)}{residuals.get(p.id)!.toFixed(1)} m{:else}<span class="muted">–</span>{/if}
												</td>
												<td><button class="ghost x" title="Remove pin {p.id}" onclick={() => removePin(p.id)}>✕</button></td>
											</tr>
										{/each}
									</tbody>
								</table>
							{/if}
							<p class="muted small">
								{#if pinFit}
									Fitted from {pairs.length} pins ({pinFit.kind === 'affine' ? 'stretch & skew' : 'move, turn & scale'}){#if rms != null}{' · '}typical error {rms.toFixed(1)} m; a pin far off the rest is probably misplaced{/if}.
									{#if pairs.length === minPins(pinFit.kind)}Add another pin to check the fit.{/if}
								{:else}
									{Math.max(0, minPins(fitKind) - pairs.length)} more matched pin{minPins(fitKind) - pairs.length === 1 ? '' : 's'} to fit the sheet.
								{/if}
							</p>
							<div class="field">
								<label for="fk">Fit</label>
								<select id="fk" bind:value={fitChoice}>
									<option value="auto">Automatic</option>
									<option value="similarity">Move, turn &amp; scale only (2+ pins)</option>
									<option value="affine">Also stretch &amp; skew (3+ pins)</option>
								</select>
							</div>
							{#if pins.length}<button class="ghost" onclick={clearPins}>Clear pins</button>{/if}
						{/if}
						{#if narrow}
							<button class="primary" onclick={() => (panelOpen = false)}>Back to full-screen aligning</button>
						{/if}
						<button class={narrow ? 'ghost' : 'primary'} onclick={() => (aligning = false)}>Done aligning</button>
					{/if}
					<div class="row" style="margin-top: 10px">
						<button class="ghost" onclick={exportAlignment} title="Download the corner positions as a small JSON file">Save alignment file</button>
						<label class="btn ghost filebtn">
							Load alignment
							<input type="file" accept=".json,application/json" onchange={importAlignment} />
						</label>
					</div>
					<p class="hint">Alignment files keep your work between sessions; the scan itself never leaves your computer.</p>
				{/if}
				<p class="hint">Next: switch to <button class="link" onclick={() => (tool = 'trace')}>Trace</button> to draw footprints and streets over it.</p>
			{/if}
		{/if}

		<!-- ======================= TRACE ======================= -->
		{#if tool === 'trace'}
			<p class="hint">
				Click to place vertices over the overlay. Corners snap to existing shapes. Drag the <span class="sw move"></span> handle to move the
				whole shape. <kbd>Backspace</kbd> undoes, <kbd>Esc</kbd> clears.
			</p>
			<div class="opacity">
				{#if activeSource}
					<div class="field">
						<label for="tso">Scan opacity {compare === 'swipe' ? '(swipe mode)' : `${Math.round(opacity * 100)}%`}</label>
						<input id="tso" type="range" min="0" max="1" step="0.05" bind:value={opacity} disabled={compare === 'swipe'} />
					</div>
				{/if}
				<div class="field">
					<label for="tsf">Shape fill {Math.round(shapeFill * 100)}%</label>
					<input id="tsf" type="range" min="0" max="1" step="0.05" bind:value={shapeFill} />
				</div>
				<div class="field">
					<label for="tsl">Shape outline {Math.round(shapeLine * 100)}%</label>
					<input id="tsl" type="range" min="0.1" max="1" step="0.05" bind:value={shapeLine} />
				</div>
			</div>
			<div class="seg">
				{#each ['polygon', 'line', 'point'] as const as m (m)}
					<button class:on={drawMode === m} onclick={() => ((drawMode = m), (pts = []))}>{m}</button>
				{/each}
			</div>
			<p class="muted small">{pts.length} vertices {geometry ? '· ready' : ''}</p>
			<h3>Export</h3>
			<p class="hint">
				Take the shape away as GeoJSON (lon/lat, EPSG:4326) without creating or changing a page. The name, kind and role below, and the
				year, go in its properties.
			</p>
			<div class="row exports">
				<button disabled={!geometry} onclick={() => download([currentFeature()!])} title="Save this shape as a .geojson file">Download</button>
				<button disabled={!geometry} onclick={() => copy([currentFeature()!])} title="Copy this shape as GeoJSON">Copy</button>
				<button disabled={!geometry} onclick={keepShape} title="Set this shape aside and draw another, then export them together">Keep &amp; draw another</button>
			</div>
			{#if kept.length}
				<div class="kept-box">
					<div class="spread">
						<strong>{kept.length} kept shape{kept.length === 1 ? '' : 's'}</strong>
						<button class="ghost x" onclick={() => (kept = [])} title="Forget all kept shapes">Clear</button>
					</div>
					<ul class="plain-list">
						{#each kept as f, i (i)}
							<li class="small">
								<span class="sw kept"></span>
								{f.properties?.name ?? `${f.properties?.kind} ${f.geometry.type.toLowerCase()}`}
								<span class="muted">· {f.properties?.year}</span>
								<button class="ghost x" title="Remove" onclick={() => kept.splice(i, 1)}>✕</button>
							</li>
						{/each}
					</ul>
					<div class="row exports">
						<button onclick={() => download(kept)}>Download all</button>
						<button onclick={() => copy(kept)}>Copy all</button>
						{#if geometry}<span class="muted small">(the shape you're drawing isn't included until you keep it)</span>{/if}
					</div>
				</div>
			{/if}
			{#if exportNote}<p class="notice ok small">{exportNote}</p>{/if}
			<p class="hint">Kept shapes stay in this browser tab only and are gone when you leave the page.</p>

			<hr />
			<h3>…or save it to a page</h3>
			<form method="post" action="?/trace" class="stack" use:enhance={() => after()}>
				<input type="hidden" name="tool" value="trace" />
				<input type="hidden" name="geojson" value={geojsonText} />
				<div>
					<label for="te">Add to existing page…</label>
					<EntityPicker id="te" name="entity_id" />
				</div>
				<p class="muted small">…or create a new one:</p>
				<div class="fields">
					<div><label for="tn">Name</label><input id="tn" name="name" placeholder="Hardware store" bind:value={traceName} /></div>
					<div>
						<label for="tk">Kind</label>
						<select id="tk" name="kind" bind:value={traceKind}>{#each spatialKinds as k (k.id)}<option value={k.id}>{k.label}</option>{/each}</select>
					</div>
					<div>
						<label for="ts">Condition</label>
						<select id="ts" name="status"><option value="">(unknown)</option>{#each data.vocab.statuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}</select>
					</div>
					<div>
						<label for="tr">Role</label>
						<select id="tr" name="role" bind:value={traceRole}>{#each ['footprint', 'shape', 'centerline', 'boundary', 'point'] as r (r)}<option>{r}</option>{/each}</select>
					</div>
				</div>
				<TemporalFields
					sources={data.sources}
					idPrefix="tr"
					values={{ valid_from: `${/^\d{4}$/.test(depictsYear) ? depictsYear : year}-01-01`, valid_from_precision: 'year', confidence: 'probable' }}
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
						<div><label for="anote">Note</label><input id="anote" name="note" placeholder="Cleared for the expressway" /></div>
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

	<div class="stage" class:split={pinning}>
		{#if pinning && scan}
			<div class="scanpane" class:await={pinStep.where === 'scan'}>
				<ScanPinView
					url={scan.url}
					width={scan.width}
					height={scan.height}
					{pins}
					waiting={waitingImg != null && !(waitingMap != null && pins.find((p) => p.id === waitingMap)?.img) ? waitingImg : null}
					onpin={addImgPin}
					onmove={moveImgPin}
				/>
			</div>
		{/if}
		<div class="mapwrap" class:await={pinning && pinStep.where === 'map'}>
			<div class="map" bind:this={mapEl}></div>
			<div class="top" bind:this={topEl} class:hidden={compare !== 'swipe' || !activeSource} style:clip-path="inset(0 {100 - swipe * 100}% 0 0)"></div>
			{#if compare === 'swipe' && activeSource}
				<div class="swipe" style:left="{swipe * 100}%" onpointerdown={() => (dragging = true)} role="slider" aria-valuenow={Math.round(swipe * 100)} aria-label="Swipe position" tabindex="0">
					<span>⇔</span>
				</div>
			{/if}
			{#if scan && aligning}
				<div class="banner">
					{#if alignMode === 'pins'}
						Pinning: a spot on the scan, then the same spot here
					{:else}
						Aligning: drag the corners · lower the opacity to see streets beneath
					{/if}
				</div>
			{/if}
			<div class="map-tl">
				{#if can('edit_content')}
					<button
						class="select-btn"
						class:on={selecting}
						onclick={() => (selecting ? stopSelecting() : ((selecting = true), (aligning = false)))}
						title={narrow ? 'Tap buildings to select them for bulk edits' : 'Click buildings to select them for bulk edits (or Shift-click / Shift-drag any time)'}
					>
						{selecting ? 'Done selecting' : selected.length ? `Select (${selected.length})` : 'Select'}
					</button>
				{/if}
				{#if activeSource}<div class="session-badge" title="Not uploaded or saved; gone when you close the page">session-only scan</div>{/if}
			</div>
			{#if box}
				<div
					class="select-box"
					style:left="{Math.min(box.x0, box.x1)}px"
					style:top="{Math.min(box.y0, box.y1)}px"
					style:width="{Math.abs(box.x1 - box.x0)}px"
					style:height="{Math.abs(box.y1 - box.y0)}px"
				></div>
			{/if}
			<div class="dock">
				<YearSlider bind:year min={Math.min(data.minYear, data.settings.min_year)} max={data.maxYear} />
			</div>
		</div>
	</div>
	{#if focus && scan}
		<div class="alignbar">
			<div class="bar-row">
				<div class="seg">
					<button class:on={alignMode === 'corners'} onclick={() => (alignMode = 'corners')}>Corners</button>
					<button class:on={alignMode === 'pins'} onclick={() => (alignMode = 'pins')}>Pins</button>
				</div>
				<button class="primary" onclick={() => (aligning = false)}>Done</button>
			</div>
			{#if alignMode === 'corners'}
				<p class="bar-tip">Drag the <span class="sw corner"></span> corners onto matching street corners; drag <span class="sw move"></span> to move the sheet.</p>
				<label class="bar-op">
					<span>Opacity</span>
					<input type="range" min="0" max="1" step="0.05" bind:value={opacity} aria-label="Scan opacity" />
				</label>
				<div class="bar-nudges">
					<button title="Rotate left" onclick={() => transform(-1, 1)}>⟲ 1°</button>
					<button title="Rotate right" onclick={() => transform(1, 1)}>⟳ 1°</button>
					<button title="Rotate left a little" onclick={() => transform(-0.2, 1)}>⟲ .2°</button>
					<button title="Rotate right a little" onclick={() => transform(0.2, 1)}>⟳ .2°</button>
					<button title="Shrink" onclick={() => transform(0, 0.98)}>− 2%</button>
					<button title="Grow" onclick={() => transform(0, 1.02)}>+ 2%</button>
				</div>
			{:else}
				<p class="bar-next">
					<span class="pin-no">{pinStep.id}</span>
					<span>{#if pinStep.where === 'map'}Now tap the same spot on the <strong>map</strong> ↓{:else}Tap a recognisable spot on the <strong>scan</strong> ↑{/if}</span>
				</p>
				<div class="bar-row">
					<span class="muted small">
						{#if pinFit}{pairs.length} pins{#if rms != null} · typical error {rms.toFixed(1)} m{/if}{:else}{Math.max(0, minPins(fitKind) - pairs.length)} more matched pin{minPins(fitKind) - pairs.length === 1 ? '' : 's'} to fit{/if}
					</span>
					<span class="spacer"></span>
					<button class="ghost" disabled={!pins.length} onclick={() => removePin(pins[pins.length - 1].id)}>Undo pin</button>
					<button class="ghost" disabled={!pins.length} onclick={clearPins}>Clear</button>
				</div>
			{/if}
			<button class="link more" onclick={() => (panelOpen = true)}>More options (fit, alignment files, year…)</button>
		</div>
	{/if}
	{#if selectFocus}
		<div class="alignbar selectbar">{@render selectionUI()}</div>
	{/if}
</div>

{#snippet selectionUI()}
	<div class="bar-row">
		<strong class="sel-count">{selected.length} selected</strong>
		<span class="spacer"></span>
		{#if selecting || narrow}
			<button class="ghost small-btn" class:on={boxMode} onclick={() => (boxMode = !boxMode)} title="Drag a box to select everything in it">Box</button>
		{/if}
		{#if selected.length}<button class="ghost small-btn" onclick={() => ((selected = []), (bulkResult = null))}>Clear</button>{/if}
		<button class="ghost small-btn" onclick={() => ((selected = []), (bulkResult = null), stopSelecting())}>Done</button>
	</div>
	{#if form && form.tool === 'select' && 'error' in form && form.error}<p class="notice error small">{form.error}</p>{/if}
	{#if bulkResult}
		<div class="notice small {bulkResult.done ? 'ok' : 'error'}">
			{bulkResult.done
				? `${bulkResult.done} marked ${
						bulkResult.action === 'gone'
							? `gone by ${bulkResult.at}`
							: bulkResult.action === 'condition'
								? `${statusLabel(bulkResult.status)} from ${bulkResult.at}`
								: `still standing in ${bulkResult.at}`
					}.`
				: 'Nothing changed.'}
			{#if bulkResult.skipped.length}
				{bulkResult.skipped.length} skipped (still selected):
				<ul class="skipped">
					{#each bulkResult.skipped as k (k.id)}<li><span><a href="/e/{k.slug}" target="_blank" rel="noopener">{k.name}</a>{': ' + k.reason}</span></li>{/each}
				</ul>
			{/if}
		</div>
	{/if}
	{#if !selected.length}
		<p class="hint">
			{narrow || selecting ? 'Tap' : 'Shift-click'} buildings to select them{boxMode ? ', or drag a box' : narrow ? '; Box selects a whole area' : ', or Shift-drag a box'}. Then mark
			them gone by a year (missing from an aerial), or still standing.
		</p>
	{:else}
		<details class="sel-list">
			<summary>{selected.map((x) => x.name).slice(0, 3).join(', ')}{selected.length > 3 ? ` and ${selected.length - 3} more` : ''}</summary>
			<ul>
				{#each selected as x (x.id)}
					<li>
						<a href="/e/{x.slug}" target="_blank" rel="noopener">{x.name}</a>
						<span class="muted small">{x.ghost ? 'gone' : (x.status ?? x.kind)}</span>
						<button class="ghost x" title="Unselect" onclick={() => (selected = selected.filter((y) => y.id !== x.id))}>✕</button>
					</li>
				{/each}
			</ul>
		</details>
		<form method="post" action={bulkMode === 'gone' ? '?/bulkGone' : bulkMode === 'condition' ? '?/bulkCondition' : '?/bulkStanding'} class="bulk" use:enhance={afterBulk}>
			<input type="hidden" name="tool" value="select" />
			{#each selected as x (x.id)}<input type="hidden" name="ids" value={x.id} />{/each}
			<div class="seg bulk-mode" role="radiogroup" aria-label="What to record">
				<button type="button" class:on={bulkMode === 'gone'} onclick={() => ((bulkMode = 'gone'), (bulkNoteInput = null))}>Gone by</button>
				<button type="button" class:on={bulkMode === 'condition'} onclick={() => ((bulkMode = 'condition'), (bulkNoteInput = null))}>Condition from</button>
				<button type="button" class:on={bulkMode === 'standing'} onclick={() => (bulkMode = 'standing')}>Still standing in</button>
			</div>
			<div class="bulk-fields">
				<label>
					<span>{bulkMode === 'gone' ? 'Gone by' : bulkMode === 'condition' ? 'From' : 'Standing in'}</span>
					<input name="at" value={bulkYear} oninput={(e) => (bulkYearInput = e.currentTarget.value)} placeholder="1958 · May 1958 · 1950s" title="A year, a month, a day, or a decade" />
				</label>
				{#if bulkMode === 'gone'}
					<label>
						<span>Now</span>
						<select name="status">{#each goneStatuses as st (st.id)}<option value={st.id} selected={st.id === 'demolished'}>{st.label}</option>{/each}</select>
					</label>
				{:else if bulkMode === 'condition'}
					<label>
						<span>Condition</span>
						<select name="condition" bind:value={bulkCondition} onchange={() => (bulkNoteInput = null)}>
							{#each standingStatuses as st (st.id)}<option value={st.id}>{st.label}</option>{/each}
						</select>
					</label>
				{/if}
			</div>
			{#if bulkMode !== 'standing'}
				<label class="bulk-note">
					<span>Note</span>
					<input name="note" value={bulkNote} oninput={(e) => (bulkNoteInput = e.currentTarget.value)} />
				</label>
			{/if}
			<button class="primary" disabled={bulkBusy}>
				{bulkMode === 'gone'
					? `Mark ${selected.length} gone by ${bulkYear}`
					: bulkMode === 'condition'
						? `Mark ${selected.length} ${statusLabel(bulkCondition)} from ${bulkYear}`
						: `Mark ${selected.length} still standing in ${bulkYear}`}
			</button>
			<p class="hint">
				{#if bulkMode === 'gone'}
					Ends each lifespan then, closes what was still running, and adds the condition (marked approximate). Pages with facts after
					that year are skipped.
				{:else if bulkMode === 'condition'}
					Starts the condition then (approximate), up to the next recorded one; what's recorded later, like a demolition, stays.
				{:else}
					For ones marked gone that a later aerial still shows: reopens them, and removes a guessed demolition.
				{/if}
			</p>
		</form>
	{/if}
{/snippet}

<style>
	.wb {
		display: grid;
		grid-template-columns: 330px 1fr;
		height: calc(100vh - var(--header-h));
		/* phones: the visible height, not the height behind the browser's address bar */
		height: calc(100dvh - var(--header-h));
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
	.opacity {
		display: grid;
		gap: 2px;
		margin-bottom: 10px;
	}
	.opacity .field {
		margin: 0;
	}
	.opacity input[type='range'] {
		width: 100%;
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
	.sw.kept {
		background: #e08a4a;
		border-radius: 2px;
	}
	.exports {
		flex-wrap: wrap;
		gap: 4px;
		align-items: center;
	}
	.kept-box {
		margin-top: 8px;
		padding: 6px 8px;
		border: 1px dashed #e08a4a;
		border-radius: 4px;
	}
	.kept-box li {
		display: flex;
		align-items: center;
		gap: 6px;
	}
	.kept-box li button {
		margin-left: auto;
	}
	.sw.pin {
		background: #e0574a;
		border-radius: 50%;
	}
	.stage {
		position: relative;
		min-width: 0;
		display: grid;
		grid-template-columns: 1fr;
	}
	.stage.split {
		grid-template-columns: 1fr 1fr;
	}
	.scanpane,
	.mapwrap {
		position: relative;
		min-width: 0;
		min-height: 0;
		overflow: hidden;
	}
	.scanpane {
		border-right: 2px solid var(--amber);
	}
	.next {
		margin: 6px 0;
		padding: 6px 8px;
		border-radius: 4px;
		background: rgba(224, 87, 74, 0.12);
		border: 1px solid rgba(224, 87, 74, 0.4);
	}
	table.pins {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.8rem;
		margin: 6px 0;
	}
	table.pins th,
	table.pins td {
		padding: 2px 4px;
		text-align: left;
		border-bottom: 1px solid var(--line);
	}
	table.pins td.bad {
		color: #e0574a;
		font-weight: 600;
	}
	.pin-no {
		display: inline-grid;
		place-items: center;
		width: 18px;
		height: 18px;
		border-radius: 50%;
		background: #e0574a;
		color: #fff;
		font: 700 0.65rem/1 var(--mono);
	}
	button.x {
		padding: 0 6px;
		font-size: 0.75rem;
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
	.session-badge {
		position: absolute;
		top: 10px;
		left: 10px;
		z-index: 3;
		font-family: var(--mono);
		font-size: 0.7rem;
		padding: 2px 8px;
		border-radius: 999px;
		background: rgba(20, 17, 15, 0.85);
		color: var(--amber);
		border: 1px solid var(--amber);
	}
	.loaded {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 8px;
		margin-bottom: 10px;
		word-break: break-all;
	}
	.filebtn {
		position: relative;
		overflow: hidden;
	}
	.filebtn input {
		position: absolute;
		inset: 0;
		opacity: 0;
		cursor: pointer;
	}
	button.link {
		background: none;
		border: 0;
		padding: 0;
		color: var(--rust-2);
		font: inherit;
		cursor: pointer;
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
	:global(.handle.pin) {
		width: 22px;
		height: 22px;
		display: grid;
		place-items: center;
		background: #e0574a;
		color: #fff;
		border-radius: 50%;
		font: 700 0.7rem/1 var(--mono, monospace);
		box-shadow:
			0 0 0 2px #17130f,
			0 0 0 4px rgba(255, 255, 255, 0.85);
	}
	:global(.handle.pin.half) {
		opacity: 0.75;
	}
	/* where the next pin tap goes */
	.scanpane.await::after,
	.mapwrap.await::after {
		content: '';
		position: absolute;
		inset: 0;
		box-shadow: inset 0 0 0 3px #e0574a;
		pointer-events: none;
		z-index: 2;
	}
	/* fingers need bigger handles */
	@media (pointer: coarse) {
		:global(.handle.corner) {
			width: 30px;
			height: 30px;
			border-radius: 5px;
		}
		:global(.handle.move) {
			width: 36px;
			height: 36px;
		}
		:global(.handle.pin) {
			width: 32px;
			height: 32px;
			font-size: 0.8rem;
		}
	}
	.map-tl {
		position: absolute;
		top: 10px;
		left: 10px;
		z-index: 3;
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.map-tl .session-badge {
		position: static;
	}
	.select-btn {
		padding: 5px 12px;
		font-size: 0.8rem;
		background: rgba(20, 17, 15, 0.9);
		border-color: var(--line-2);
	}
	.select-btn.on,
	.small-btn.on {
		background: #f2c14e;
		border-color: #f2c14e;
		color: #17130f;
	}
	.select-box {
		position: absolute;
		z-index: 4;
		border: 2px dashed #f2c14e;
		background: rgba(242, 193, 78, 0.12);
		pointer-events: none;
	}
	.selection {
		display: grid;
		gap: 8px;
		margin-bottom: 12px;
		border-color: #f2c14e;
	}
	.sel-count {
		font-size: 0.95rem;
	}
	.small-btn {
		padding: 3px 10px;
		font-size: 0.78rem;
	}
	.sel-list summary {
		cursor: pointer;
		color: var(--ink-2);
	}
	.sel-list ul,
	.skipped {
		margin: 6px 0 0;
		padding-left: 0;
		list-style: none;
		max-height: 160px;
		overflow-y: auto;
	}
	.sel-list li,
	.skipped li {
		display: flex;
		gap: 6px;
		align-items: baseline;
		padding: 2px 0;
	}
	.sel-list li button {
		margin-left: auto;
	}
	.bulk {
		display: grid;
		gap: 6px;
	}
	.bulk-mode {
		margin: 0;
	}
	.bulk-mode button {
		font-size: 0.75rem;
		text-transform: none;
	}
	.bulk-fields {
		display: grid;
		grid-template-columns: 1fr 1.4fr;
		gap: 8px;
	}
	.bulk label {
		display: grid;
		gap: 2px;
		margin: 0;
		font-size: 0.78rem;
		color: var(--muted);
	}
	.selectbar {
		/* of the screen: a percentage would be of its own (content-sized) row */
		max-height: 48vh;
		max-height: 48dvh;
		overflow-y: auto;
		border-top-color: #f2c14e;
	}
	.alignbar {
		display: grid;
		gap: 6px;
		padding: 8px 12px calc(8px + env(safe-area-inset-bottom));
		background: var(--bg-2);
		border-top: 2px solid var(--amber);
		font-size: 0.85rem;
	}
	.alignbar .seg {
		margin: 0;
		flex: 1;
	}
	.bar-row {
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.bar-row .spacer {
		flex: 1;
	}
	.bar-tip,
	.bar-next {
		margin: 0;
		color: var(--ink-2);
	}
	.bar-next {
		display: flex;
		align-items: center;
		gap: 8px;
		color: var(--ink);
	}
	.bar-op {
		display: flex;
		align-items: center;
		gap: 10px;
		margin: 0;
		color: var(--ink-2);
	}
	.bar-op input {
		flex: 1;
	}
	.bar-nudges {
		display: grid;
		grid-template-columns: repeat(6, 1fr);
		gap: 4px;
	}
	.bar-nudges button {
		justify-content: center;
		padding: 8px 0;
		font-size: 0.78rem;
	}
	.alignbar .more {
		justify-self: start;
		font-size: 0.8rem;
	}
	@media (max-width: 800px) {
		.wb {
			grid-template-columns: 1fr;
			grid-template-rows: 45% 1fr;
		}
		/* full-screen aligning: the scan/map above, the control bar below */
		.wb.focus {
			grid-template-rows: 1fr auto;
		}
		.wb.focus .panel,
		.wb.focus .dock,
		.wb.focus .banner {
			display: none;
		}
		.wb.focus {
			grid-template-rows: minmax(0, 1fr) auto;
		}
		.banner {
			top: 42px;
			max-width: calc(100% - 90px);
			text-align: center;
		}
		.stage.split {
			grid-template-columns: 1fr;
			grid-template-rows: 1fr 1fr;
		}
		.scanpane {
			border-right: 0;
			border-bottom: 2px solid var(--amber);
		}
	}
</style>
