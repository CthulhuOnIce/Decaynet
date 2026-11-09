<script lang="ts">
	import 'maplibre-gl/dist/maplibre-gl.css';
	import { onDestroy, onMount, tick, untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import type { GeoJSONSource, ImageSource, Map as MLMap, Marker } from 'maplibre-gl';
	import YearSlider from '$lib/components/YearSlider.svelte';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import TemporalFields from '$lib/components/TemporalFields.svelte';
	import SourcePicker from '$lib/components/SourcePicker.svelte';
	import { JPEG2000_ACCEPT, decodeJpeg2000, isJpeg2000 } from '$lib/jp2';
	import {
		CRS_PRESETS,
		GEO_ACCEPT,
		centreOf,
		crsFromEpsg,
		crsFromText,
		decodeTiff,
		gatherScanSets,
		georefPins,
		guessCrs,
		isTiff,
		worldTransform,
		type Crs,
		type Georef
	} from '$lib/georaster';
	import { CONFIDENCES } from '$lib/types';
	import ScanPinView from '$lib/components/ScanPinView.svelte';
	import {
		WEB_MERCATOR_PRJ,
		apply,
		cornersFor,
		fit,
		fromMerc,
		mercPerMetre,
		metres,
		minPins,
		northTurn,
		placeAt,
		poseOf,
		rigidFit,
		toMerc,
		worldFile,
		type Affine,
		type FitKind,
		type XY
	} from '$lib/map/georef';
	import type { CrossingHit } from '$lib/map/crossings';
	import { baseStyle, colorFeatures, mapView, snapshotLayers, type ColorBy } from '$lib/map/style';
	import { loadView, saveView, loadYear, saveYear } from '$lib/mapMemory';
	import { can } from '$lib/perms';
	import { yearToDate } from '$lib/time';

	let { data, form } = $props();

	type Tool = 'overlay' | 'trace' | 'import';
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
	// What the map shows (the View controls on the map, in every tool)
	let showShapes = $state(true); // existing shapes: hide them to trace without the old footprint in the way (H)
	let showBase = $state(true);
	let scanOff = $state(false);
	// condition (with "no condition yet" in the site's colour) or article status: shows the work left
	let colorBy = $state<ColorBy>('condition');
	let compare = $state<'blend' | 'swipe'>('blend');
	let swipe = $state(0.5);
	/** the sheet on the map; full size is the image's own, when it's shown reduced */
	let scan = $state<{ name: string; url: string; corners: Corners; width: number; height: number; fullWidth: number; fullHeight: number } | null>(null);
	let tileUrl = $state('');
	let tileInput = $state('');
	let aligning = $state(true); // show corner handles
	// Phones: aligning takes the whole screen (scan and/or map) with a compact control bar;
	// "More options" brings the full panel back
	let narrow = $state(false);
	let panelOpen = $state(false);
	// phones: fold the tool panel down to its tabs, so the map gets the screen (while tracing, say)
	let panelHidden = $state(false);
	let depictsYear = $state(''); // year the scan shows; pre-fills traced shapes
	let markers: Marker[] = [];
	let scanError = $state<string | null>(null);
	let scanBusy = $state<string | null>(null);
	/** set when a big JPEG 2000 sheet was decoded at a reduced resolution to fit the browser */
	let scanNote = $state<string | null>(null);
	// a georeferenced scan (GeoTIFF, or a world file): where it says it is, and in which coordinate system
	type ScanSize = { width: number; height: number; fullWidth: number; fullHeight: number };
	let scanGeo = $state<{ geo: Georef; size: ScanSize; crs: Crs | null; guessed: boolean; problem: string | null } | null>(null);
	let crsText = $state('');
	let crsPaste = $state(false);

	// Two ways to align a scan: drag its four corners, or match pins (control
	// points) on the scan to the same spots on the map and fit the sheet to them.
	/** label: the street corner it was looked up as */
	type Pin = { id: number; img: XY | null; map: XY | null; label?: string };
	let alignMode = $state<'corners' | 'pins'>('corners');
	let pins = $state<Pin[]>([]);
	let pinSeq = $state(0);
	type FitChoice = 'auto' | FitKind | 'rigid';
	let fitChoice = $state<FitChoice>('auto');
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
		if (m?.getLayer('overlay')) m.setPaintProperty('overlay', 'raster-opacity', overlayHidden || scanOff ? 0 : compare === 'swipe' ? 1 : opacity);
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
		scanAligned = true;
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

	// ---------------------------------------------------------------- the book: several sheets, one at a time
	// Open a whole Sanborn volume (or any set of sheets): each is aligned in turn, and the ones done
	// stay on the map, small, to line the next one up against. Export writes them all out as world
	// files (Web Mercator), alignment files and an index of the sheets: for QGIS, or for picking the
	// book up here again. Like a single scan, nothing leaves the browser.
	type Alignment = {
		decaynet_alignment: 1;
		file: string;
		width: number;
		height: number;
		full_width: number;
		full_height: number;
		depicts: string | null;
		corners: Corners;
		pins: { image: XY; map: XY; label?: string }[];
		scale_bar: { image: [XY, XY]; length: number | null; unit: ScaleUnit } | null;
		north_arrow: [XY, XY] | null;
		aligned: boolean;
	};
	type Sheet = {
		id: number;
		name: string;
		file: File;
		world: number[] | null;
		prj: string | null;
		/** an alignment file it came with, or where it was left when another sheet was opened */
		alignment: Alignment | null;
		geo: typeof scanGeo;
		/** a small copy for the map while another sheet is being aligned */
		thumb: string | null;
		aligned: boolean;
	};
	let book = $state<Sheet[]>([]);
	let sheetSeq = 0;
	/** the sheet that's `scan` */
	let current = $state<number | null>(null);
	/** the open sheet has been placed (pins, corners, georeferencing), not just dropped in the view */
	let scanAligned = $state(false);
	let showBook = $state(true);
	let bookImages = $state(true);
	let bookBusy = $state<string | null>(null);
	let bookNote = $state<string | null>(null);
	const alignedCount = $derived(book.filter((s) => (s.id === current ? scanAligned : s.aligned)).length);

	async function openScan(e: Event) {
		const input = e.currentTarget as HTMLInputElement;
		const picked = [...(input.files ?? [])];
		// so choosing the same file again opens it again
		input.value = '';
		if (!picked.length || !map) return;
		scanError = null;
		bookNote = null;
		try {
			// zips, images picked with their world files and .prj, a book's export
			if (picked.length > 1 || /\.zip$/i.test(picked[0].name)) scanBusy = 'Unpacking…';
			const { sets, note } = await gatherScanSets(picked).finally(() => (scanBusy = null));
			const added: Sheet[] = sets.map((s) => ({
				id: ++sheetSeq,
				name: s.image.name,
				file: s.image,
				world: s.world,
				prj: s.prj,
				alignment: readAlignment(s.alignment),
				geo: null,
				thumb: null,
				aligned: false
			}));
			for (const a of added) a.aligned = !!a.alignment?.aligned;
			const fresh = added.filter((a) => !book.some((b) => b.name === a.name));
			book.push(...fresh);
			const notes = [note, fresh.length < added.length ? `${added.length - fresh.length} already in the book.` : null].filter(Boolean).join(' ') || null;
			if (!scan && fresh.length) await openSheet(fresh[0].id, notes);
			else bookNote = [fresh.length ? `${fresh.length} sheet${fresh.length === 1 ? '' : 's'} added to the book.` : null, notes].filter(Boolean).join(' ');
		} catch (err) {
			scanError = `Couldn't open that: ${(err as Error).message}`;
		}
	}

	/**
	 * Make a sheet of the book the one on the map: decoded, and placed where it was left, or by its
	 * alignment file, or by its georeferencing, or in the middle of the view.
	 */
	async function openSheet(id: number, note: string | null = null) {
		const sheet = book.find((s) => s.id === id);
		if (!sheet || !map || id === current) return;
		if (scan) await stashSheet();
		scanError = null;
		scanNote = null;
		scanGeo = null;
		crsPaste = false;
		const file = sheet.file;
		try {
			const notes: string[] = note ? [note] : [];
			let image: Blob = file;
			let full: { fullWidth: number; fullHeight: number } | null = null;
			let geo: Georef | null = null;
			if (await isTiff(file)) {
				// TIFF / GeoTIFF: decoded here, in a worker, with its georeferencing
				scanBusy = `Reading ${file.name}…`;
				const t = await decodeTiff(file).finally(() => (scanBusy = null));
				image = t.blob;
				full = t;
				if (t.width < t.fullWidth)
					notes.push(`Shown at ${t.width.toLocaleString()} × ${t.height.toLocaleString()} px (the image is ${t.fullWidth.toLocaleString()} × ${t.fullHeight.toLocaleString()}): as much as this browser can draw.`);
				if (t.geo) geo = { transform: t.geo.transform, epsg: t.geo.epsg, prj: sheet.prj, citation: t.geo.citation, from: 'GeoTIFF' };
			} else if (await isJpeg2000(file)) {
				// JPEG 2000 (the Library of Congress's Sanborn sheets): decoded here, in a worker
				scanBusy = `Decoding ${file.name}…`;
				const t = await decodeJpeg2000(file).finally(() => (scanBusy = null));
				image = t.blob;
				full = t;
				if (t.width < t.fullWidth)
					notes.push(`Shown at ${t.width.toLocaleString()} × ${t.height.toLocaleString()} px (the sheet is ${t.fullWidth.toLocaleString()} × ${t.fullHeight.toLocaleString()}): as much as this browser can draw. Alignment files still match it on any device.`);
			}
			if (!geo && sheet.world) geo = { transform: worldTransform(sheet.world), epsg: null, prj: sheet.prj, citation: null, from: 'world file' };
			const url = URL.createObjectURL(image);
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
			resetAlignment();
			current = id;
			scan = {
				name: file.name,
				url,
				width: img.width,
				height: img.height,
				fullWidth: full?.fullWidth ?? img.width,
				fullHeight: full?.fullHeight ?? img.height,
				corners: [ll(x0, y0), ll(x0 + w, y0), ll(x0 + w, y0 + h), ll(x0, y0 + h)]
			};
			scanAligned = false;
			scanNote = notes.join(' ') || null;
			if (sheet.alignment) {
				// where it was left (or its alignment file); its georeferencing choices come back too
				applyAlignment(sheet.alignment);
				if (sheet.geo) scanGeo = sheet.geo;
				if (sheet.alignment.pins.length) alignMode = 'pins';
			} else if (geo) placeGeo(geo, { width: img.width, height: img.height, fullWidth: scan.fullWidth, fullHeight: scan.fullHeight });
			if (!depictsYear || !sheet.alignment?.depicts) {
				const y = file.name.match(/(1[89]\d\d|20\d\d)/);
				if (y && !sheet.alignment?.depicts) {
					depictsYear = y[1];
					year = Number(y[1]);
				}
			}
		} catch (err) {
			scanError = `Couldn't open ${file.name}: ${(err as Error).message}`;
			// a sheet that can't be read is no use in the book
			if (!sheet.alignment && !sheet.thumb) book = book.filter((s) => s.id !== id);
		}
	}

	/** Put the open sheet back in the book: where it is now, and a small copy to show on the map. */
	async function stashSheet() {
		if (!scan) return;
		const sheet = book.find((s) => s.id === current);
		if (sheet) {
			sheet.alignment = alignmentNow();
			sheet.aligned = scanAligned;
			sheet.geo = scanGeo ? $state.snapshot(scanGeo) : null;
			const old = sheet.thumb;
			sheet.thumb = await thumbnail(scan.url).catch(() => null);
			if (old) URL.revokeObjectURL(old);
		}
		closeScan();
	}

	/** A copy at most 1600 px across, for the map: a whole book at full size would run out of graphics memory. */
	async function thumbnail(url: string): Promise<string> {
		const bmp = await createImageBitmap(await (await fetch(url)).blob());
		const k = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
		const c = document.createElement('canvas');
		c.width = Math.max(1, Math.round(bmp.width * k));
		c.height = Math.max(1, Math.round(bmp.height * k));
		c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
		bmp.close();
		const out = (await new Promise<Blob | null>((r) => c.toBlob(r, 'image/webp', 0.8))) ?? (await new Promise<Blob | null>((r) => c.toBlob(r, 'image/png')));
		if (!out) throw new Error('no thumbnail');
		return URL.createObjectURL(out);
	}

	/** The next sheet still to align (after this one, round to the start), else simply the next. */
	function nextSheet() {
		const i = book.findIndex((s) => s.id === current);
		const after = [...book.slice(i + 1), ...book.slice(0, Math.max(0, i))];
		const next = after.find((s) => !s.aligned) ?? after[0];
		if (next) openSheet(next.id);
	}
	const nextUp = $derived.by(() => {
		const i = book.findIndex((s) => s.id === current);
		const after = [...book.slice(i + 1), ...book.slice(0, Math.max(0, i))];
		return after.find((s) => !s.aligned) ?? null;
	});

	function removeSheet(id: number) {
		const s = book.find((x) => x.id === id);
		if (!s) return;
		if (s.aligned && !confirm(`Take ${s.name} out of the book? Its alignment is lost unless you exported the book.`)) return;
		if (s.thumb) URL.revokeObjectURL(s.thumb);
		book = book.filter((x) => x.id !== id);
	}

	// the other sheets on the map, under the open one
	let bookOnMap = new Map<number, string>();
	function drawBook() {
		if (!map || !ready) return;
		const want = showBook && tool === 'overlay' ? book.filter((s) => s.thumb && s.alignment && s.aligned && s.id !== current) : [];
		for (const [id] of bookOnMap) {
			if (want.some((s) => s.id === id)) continue;
			if (map.getLayer(`book-${id}`)) map.removeLayer(`book-${id}`);
			if (map.getSource(`book-${id}`)) map.removeSource(`book-${id}`);
			bookOnMap.delete(id);
		}
		for (const s of want) {
			const src = map.getSource(`book-${s.id}`) as ImageSource | undefined;
			const coordinates = $state.snapshot(s.alignment!.corners) as Corners;
			if (src && bookOnMap.get(s.id) === s.thumb) src.setCoordinates(coordinates);
			else if (src) src.updateImage({ url: s.thumb!, coordinates });
			else {
				map.addSource(`book-${s.id}`, { type: 'image', url: s.thumb!, coordinates });
				map.addLayer(
					{ id: `book-${s.id}`, type: 'raster', source: `book-${s.id}`, paint: { 'raster-opacity': 0.55, 'raster-fade-duration': 0 } },
					map.getLayer('overlay') ? 'overlay' : 'snapshot-district-fill'
				);
			}
			bookOnMap.set(s.id, s.thumb!);
		}
	}

	/** The open sheet's alignment, as saved in alignment files and the book's export. */
	function alignmentNow(): Alignment | null {
		if (!scan) return null;
		return {
			decaynet_alignment: 1,
			file: scan.name,
			width: scan.width,
			height: scan.height,
			full_width: scan.fullWidth,
			full_height: scan.fullHeight,
			depicts: depictsYear || null,
			corners: $state.snapshot(scan.corners) as Corners,
			pins: pairs.map((p) => ({ image: [...p.img!] as XY, map: [...p.map!] as XY, ...(p.label ? { label: p.label } : {}) })),
			scale_bar: scaleBar.pts.length === 2 ? { image: $state.snapshot(scaleBar.pts) as [XY, XY], length: scaleBar.length, unit: scaleBar.unit } : null,
			north_arrow: north.length === 2 ? ($state.snapshot(north) as [XY, XY]) : null,
			aligned: scanAligned
		};
	}

	/** An alignment file's contents, checked; null if it isn't one. */
	function readAlignment(j: Record<string, unknown> | null): Alignment | null {
		if (!j) return null;
		const ok = (v: unknown): v is XY => Array.isArray(v) && v.length === 2 && v.every((n) => typeof n === 'number' && Number.isFinite(n));
		if (!Array.isArray(j.corners) || j.corners.length !== 4 || !j.corners.every(ok)) return null;
		const num = (v: unknown) => (typeof v === 'number' && v > 0 ? v : null);
		const sb = j.scale_bar as { image?: unknown[]; length?: unknown; unit?: unknown } | null | undefined;
		const na = j.north_arrow as unknown[] | null | undefined;
		const width = num(j.width) ?? 0;
		const height = num(j.height) ?? 0;
		return {
			decaynet_alignment: 1,
			file: typeof j.file === 'string' ? j.file : '',
			width,
			height,
			full_width: num(j.full_width) ?? width,
			full_height: num(j.full_height) ?? height,
			depicts: j.depicts != null ? String(j.depicts) : null,
			corners: j.corners as Corners,
			pins: Array.isArray(j.pins)
				? (j.pins as { image?: unknown; map?: unknown; label?: unknown }[])
						.filter((p) => ok(p?.image) && ok(p?.map))
						.map((p) => ({ image: p.image as XY, map: p.map as XY, ...(typeof p.label === 'string' ? { label: p.label } : {}) }))
				: [],
			scale_bar:
				sb && Array.isArray(sb.image) && sb.image.length === 2 && sb.image.every(ok)
					? { image: sb.image as [XY, XY], length: num(sb.length), unit: (sb.unit as ScaleUnit) in SCALE_UNITS ? (sb.unit as ScaleUnit) : 'ft' }
					: null,
			north_arrow: Array.isArray(na) && na.length === 2 && na.every(ok) ? (na as [XY, XY]) : null,
			// alignment files from before books were all of aligned sheets
			aligned: j.aligned !== false
		};
	}

	/** Put the open sheet where an alignment says, with its pins, scale bar and north arrow. */
	function applyAlignment(a: Alignment, fly = true) {
		if (!scan) return;
		// pins are in the scan's pixels: a sheet opened at another resolution (a big JPEG 2000 on
		// another device) scales them to this one
		const sx = a.width > 0 ? scan.width / a.width : 1;
		const sy = a.height > 0 ? scan.height / a.height : 1;
		const px = (p: XY): XY => [p[0] * sx, p[1] * sy];
		resetAlignment();
		setCorners(a.corners);
		if (a.depicts) {
			depictsYear = a.depicts;
			if (/^\d{4}$/.test(a.depicts)) year = Number(a.depicts);
		}
		pins = a.pins.map((p, i) => ({ id: i + 1, img: px(p.image), map: p.map, label: p.label }));
		pinSeq = pins.length;
		if (a.scale_bar) scaleBar = { pts: a.scale_bar.image.map(px), length: a.scale_bar.length, unit: a.scale_bar.unit };
		if (a.north_arrow) north = a.north_arrow.map(px);
		scanAligned = a.aligned;
		placeMarkers();
		if (fly) {
			const xs = a.corners.map((c) => c[0]);
			const ys = a.corners.map((c) => c[1]);
			map?.fitBounds([[Math.min(...xs), Math.min(...ys)], [Math.max(...xs), Math.max(...ys)]], { padding: 40, duration: 0 });
		}
	}

	const WORLD_EXT: Record<string, string> = { jp2: 'j2w', j2k: 'j2w', jpg: 'jgw', jpeg: 'jgw', png: 'pgw', tif: 'tfw', tiff: 'tfw', gif: 'gfw' };
	const stemOf = (name: string) => name.replace(/\.[^.]+$/, '');

	/**
	 * The whole book as a zip: for each sheet placed, a world file for the scan at its full
	 * resolution in Web Mercator (EPSG:3857) with a .prj, so GIS opens the scan in place; each
	 * sheet's alignment file; book.json (the sheets in order) and index.geojson (their outlines);
	 * and, if asked, the scans themselves.
	 */
	async function exportBook() {
		if (!book.length || bookBusy) return;
		bookBusy = 'Packing…';
		try {
			const { Zip, ZipDeflate, ZipPassThrough } = await import('fflate');
			const chunks: Uint8Array[] = [];
			const zip = new Zip();
			const finished = new Promise<Blob>((resolve, reject) => {
				zip.ondata = (err, data, final) => {
					if (err) return reject(err);
					chunks.push(data);
					if (final) resolve(new Blob(chunks as BlobPart[], { type: 'application/zip' }));
				};
			});
			const enc = new TextEncoder();
			const put = (name: string, data: Uint8Array, deflate = true) => {
				const f = deflate ? new ZipDeflate(name, { level: 6 }) : new ZipPassThrough(name);
				zip.add(f);
				f.push(data, true);
			};
			const features: GeoJSON.Feature[] = [];
			const listed: Record<string, unknown>[] = [];
			for (const [i, s] of book.entries()) {
				const a = s.id === current ? alignmentNow() : s.alignment;
				const aligned = s.id === current ? scanAligned : s.aligned;
				const st = stemOf(s.name);
				const ext = (s.name.match(/\.([^.]+)$/)?.[1] ?? '').toLowerCase();
				if (a) {
					put(`${st}.alignment.json`, enc.encode(JSON.stringify({ ...a, file: s.name }, null, 2)));
					const box: XY[] = [[0, 0], [a.width, 0], [a.width, a.height], [0, a.height]];
					const f = aligned ? fit(box, a.corners.map((c) => toMerc(c)), 'affine') : null;
					if (f) {
						const w = worldFile(f.m, a.width, a.height, a.full_width, a.full_height);
						put(`${st}.${WORLD_EXT[ext] ?? 'wld'}`, enc.encode(w.map((v) => v.toFixed(10)).join('\n') + '\n'));
						put(`${st}.prj`, enc.encode(WEB_MERCATOR_PRJ));
						features.push({
							type: 'Feature',
							properties: { sheet: i + 1, file: s.name, depicts: a.depicts, pins: a.pins.length },
							geometry: { type: 'Polygon', coordinates: [[...a.corners, a.corners[0]]] }
						});
					}
					listed.push({ ...a, file: s.name, aligned });
				} else {
					// never opened: its own georeferencing, as it came
					if (s.world) {
						put(`${st}.${WORLD_EXT[ext] ?? 'wld'}`, enc.encode(s.world.join('\n') + '\n'));
						if (s.prj) put(`${st}.prj`, enc.encode(s.prj));
					}
					listed.push({ file: s.name, aligned: false });
				}
				if (bookImages) {
					bookBusy = `Packing ${s.name} (${i + 1} of ${book.length})…`;
					// JPEG 2000, JPEG and PNG are compressed already
					put(s.name, new Uint8Array(await s.file.arrayBuffer()), !/^(jp2|j2k|jpe?g|png|webp|gif)$/.test(ext));
				}
			}
			put('book.json', enc.encode(JSON.stringify({ decaynet_book: 1, made: new Date().toISOString().slice(0, 10), crs: 'EPSG:3857', sheets: listed }, null, 2)));
			put('index.geojson', enc.encode(JSON.stringify({ type: 'FeatureCollection', features })));
			zip.end();
			const blob = await finished;
			const a = document.createElement('a');
			a.href = URL.createObjectURL(blob);
			a.download = `${bookName()}.zip`;
			a.click();
			setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
			bookNote = `Exported ${book.length} sheet${book.length === 1 ? '' : 's'} (${alignedCount} placed).`;
		} catch (err) {
			scanError = `Couldn't export the book: ${(err as Error).message}`;
		} finally {
			bookBusy = null;
		}
	}
	/** What the sheets' names have in common ("gary-1925-vol1-"), else "book". */
	function bookName() {
		const names = book.map((s) => stemOf(s.name));
		let p = names[0] ?? '';
		for (const n of names) while (p && !n.startsWith(p)) p = p.slice(0, -1);
		p = p.replace(/[\s._-]+$/, '').replace(/[^\w.-]+/g, '-');
		return book.length > 1 && p.length >= 3 ? `${p}-book` : book.length === 1 && p ? p : 'decaynet-book';
	}

	/** A georeferenced scan: work out its coordinate system (named, from its .prj, or guessed), then place it. */
	function placeGeo(geo: Georef, size: ScanSize) {
		let crs: Crs | null = null;
		let guessed = false;
		let problem: string | null = null;
		if (geo.epsg) {
			crs = crsFromEpsg(geo.epsg);
			if (!crs) problem = `It's in EPSG:${geo.epsg}${geo.citation ? ` (${geo.citation})` : ''}, which isn't built in. Paste its definition below (epsg.io/${geo.epsg} has it as PROJ.4 or WKT).`;
		}
		if (!crs && !problem && geo.prj) {
			crs = crsFromText(geo.prj);
			if (!crs) problem = 'Its .prj file couldn’t be read. Pick the coordinate system, or paste one below.';
		}
		if (!crs && !problem) {
			const c = map!.getCenter();
			crs = guessCrs(centreOf(geo.transform, size.fullWidth, size.fullHeight), [c.lng, c.lat]);
			guessed = !!crs;
			if (!crs) problem = `Its ${geo.from} doesn't say which coordinate system it's in, and none of the built-in ones put it near here. Pick one, or paste its definition.`;
		}
		scanGeo = { geo, size, crs, guessed, problem };
		if (crs) applyCrs(crs);
	}

	/** Place the scan by its georeferencing in this coordinate system: four corner pins, fitted like any others. */
	function applyCrs(crs: Crs) {
		if (!scanGeo || !scan || !map) return;
		const placed = georefPins(scanGeo.geo.transform, crs, scanGeo.size);
		if (!placed) {
			scanGeo = { ...scanGeo, crs, problem: `Those coordinates don't land on Earth in ${crs.label}: pick another coordinate system.` };
			return;
		}
		scanGeo = { ...scanGeo, crs, problem: null };
		clearPins();
		pins = placed.map((p, i) => ({ id: i + 1, img: p.img, map: p.map }));
		pinSeq = pins.length;
		fitChoice = 'affine';
		alignMode = 'pins';
		aligning = false;
		const lngs = placed.map((p) => p.map[0]);
		const lats = placed.map((p) => p.map[1]);
		map.fitBounds(
			[
				[Math.min(...lngs), Math.min(...lats)],
				[Math.max(...lngs), Math.max(...lats)]
			],
			{ padding: 60, duration: 600, maxZoom: 19 }
		);
	}

	function chooseCrs(id: string) {
		if (!scanGeo) return;
		if (id === '') {
			crsPaste = true;
			return;
		}
		const c = CRS_PRESETS.find((x) => x.id === id) ?? (scanGeo.crs?.id === id ? scanGeo.crs : null);
		if (!c) return;
		crsPaste = false;
		scanGeo = { ...scanGeo, guessed: false };
		applyCrs(c);
	}

	function pasteCrs() {
		if (!scanGeo) return;
		const c = crsFromText(crsText, 'Pasted');
		if (!c) {
			scanGeo = { ...scanGeo, problem: 'That isn’t a coordinate system proj4 can read: paste an EPSG code Decaynet knows, a PROJ.4 string (+proj=…) or WKT.' };
			return;
		}
		crsPaste = false;
		crsText = '';
		scanGeo = { ...scanGeo, guessed: false };
		applyCrs(c);
	}

	/** "Remove scan": confirm when an alignment would be lost; in a book, the next sheet opens. */
	function removeScan() {
		const work = !!scan && (pins.length > 0 || scanAligned);
		if (work && !confirm(`Remove ${book.length > 1 ? `${scan!.name} from the book` : 'the scan from the map'}? Its alignment is lost unless you saved it.`)) return;
		const id = current;
		const next = nextUp;
		closeScan();
		const gone = book.find((s) => s.id === id);
		if (gone?.thumb) URL.revokeObjectURL(gone.thumb);
		book = book.filter((s) => s.id !== id);
		if (next && book.some((s) => s.id === next.id)) openSheet(next.id);
		else if (book.length) openSheet(book[0].id);
		tileUrl = '';
	}

	function closeScan() {
		if (scan) URL.revokeObjectURL(scan.url);
		scan = null;
		current = null;
		scanNote = null;
		scanGeo = null;
		markers.forEach((m) => m.remove());
		markers = [];
		turnMarker?.remove();
		turnMarker = null;
		resetAlignment();
	}

	// ---------------------------------------------------------------- pin alignment
	const pinning = $derived(tool === 'overlay' && !!scan && aligning && alignMode === 'pins');
	const pairs = $derived(pins.filter((p) => p.img && p.map));

	// The sheet's scale bar and north arrow, drawn on the scan: with them one pin is enough (a street
	// corner you can name), and two pins are fitted at the bar's scale.
	const SCALE_UNITS = { ft: 0.3048, m: 1, yd: 0.9144, ch: 20.1168, rd: 5.0292, mi: 1609.344 } as const;
	type ScaleUnit = keyof typeof SCALE_UNITS;
	type ScaleBar = { pts: XY[]; length: number | null; unit: ScaleUnit };
	let scaleBar = $state<ScaleBar>({ pts: [], length: null, unit: 'ft' });
	let north = $state<XY[]>([]);
	/** what a click on the scan does */
	let scanTarget = $state<'pin' | 'scale' | 'north'>('pin');
	let scaleInput = $state<HTMLInputElement | null>(null);
	/** One pin: the sheet turns (radians, clockwise) and, without a scale bar, scales about it. */
	let turnTh = $state(0);
	let oneScale = $state<number | null>(null);
	const metresPerPx = $derived.by(() => {
		if (scaleBar.pts.length !== 2 || !scaleBar.length || scaleBar.length <= 0) return null;
		const d = Math.hypot(scaleBar.pts[1][0] - scaleBar.pts[0][0], scaleBar.pts[1][1] - scaleBar.pts[0][1]);
		return d > 0 ? (scaleBar.length * SCALE_UNITS[scaleBar.unit]) / d : null;
	});
	const northTh = $derived(north.length === 2 ? northTurn(north[0], north[1]) : null);
	/** where on Earth the sheet is (for metres → Mercator) */
	const sheetLat = $derived(pairs[0]?.map?.[1] ?? (scan ? centroid(scan.corners)[1] : 0));

	type PinFitKind = FitKind | 'rigid' | 'one';
	const needPins = (k: PinFitKind) => (k === 'one' ? 1 : k === 'rigid' ? 2 : minPins(k));
	const fitKind = $derived.by((): PinFitKind => {
		if (fitChoice === 'rigid') return metresPerPx ? 'rigid' : 'similarity';
		if (fitChoice !== 'auto') return fitChoice;
		if (pairs.length >= 3) return 'affine';
		if (pairs.length === 2) return metresPerPx ? 'rigid' : 'similarity';
		return 'one';
	});
	const pinFit = $derived.by((): { kind: PinFitKind; m: Affine } | null => {
		const k = fitKind;
		if (pairs.length < needPins(k)) return null;
		if (k === 'one') {
			const p = pairs[0];
			const s = metresPerPx ? metresPerPx * mercPerMetre(p.map![1]) : oneScale;
			return s ? { kind: k, m: placeAt(p.img!, toMerc(p.map!), s, turnTh) } : null;
		}
		if (k === 'rigid') {
			const m = rigidFit(
				pairs.map((p) => p.img!),
				pairs.map((p) => toMerc(p.map!)),
				metresPerPx! * mercPerMetre(sheetLat)
			);
			return m ? { kind: k, m } : null;
		}
		return fit(
			pairs.map((p) => p.img!),
			pairs.map((p) => toMerc(p.map!)),
			k
		);
	});
	/**
	 * How far (metres) each pin's scan spot lands from its map spot under the current fit.
	 * Only meaningful once there are more pins than the fit needs (otherwise every pin is matched exactly).
	 */
	const residuals = $derived(
		new Map<number, number>(
			pinFit && pairs.length > needPins(pinFit.kind) ? pairs.map((p) => [p.id, metres(fromMerc(apply(pinFit.m, p.img!)), p.map!)]) : []
		)
	);
	const rms = $derived(residuals.size ? Math.sqrt([...residuals.values()].reduce((s, r) => s + r * r, 0) / residuals.size) : null);
	/** with 2+ pins and a north arrow: how far the pins' turn is from the arrow's (a check on both) */
	const northOff = $derived.by(() => {
		if (!pinFit || pinFit.kind === 'one' || northTh == null) return null;
		const d = ((((poseOf(pinFit.m).th - northTh) * 180) / Math.PI + 540) % 360) - 180;
		return Math.abs(d) >= 2 ? d : null;
	});
	const waitingImg = $derived(pins.find((p) => !p.img)?.id ?? null);
	const waitingMap = $derived(pins.find((p) => !p.map)?.id ?? null);
	/** Where the next tap goes while pinning: a pin's scan spot, or its map spot. */
	const pinStep = $derived.by((): { where: 'scan' | 'map'; id: number } => {
		if (waitingMap != null && pins.find((p) => p.id === waitingMap)?.img) return { where: 'map', id: waitingMap };
		if (waitingImg != null) return { where: 'scan', id: waitingImg };
		return { where: 'scan', id: pinSeq + 1 };
	});

	/** the scale bar and north arrow, drawn on the scan pane */
	const scanLines = $derived([
		...(scaleBar.pts.length ? [{ id: 'scale', kind: 'scale', label: metresPerPx ? `${scaleBar.length} ${scaleBar.unit}` : 'scale', pts: scaleBar.pts }] : []),
		...(north.length ? [{ id: 'north', kind: 'north', label: 'N', pts: north }] : [])
	]);
	const scanTip = $derived(
		scanTarget === 'scale'
			? scaleBar.pts.length === 1
				? 'Now the other end of the scale bar'
				: 'Click one end of the scale bar'
			: scanTarget === 'north'
				? north.length === 1
					? 'Now the head of the north arrow'
					: 'Click the tail of the north arrow'
				: null
	);
	/** A click on the scan: a pin's spot, or a point of the scale bar or north arrow being drawn. */
	function scanClick(img: XY) {
		if (scanTarget === 'scale') {
			scaleBar.pts = scaleBar.pts.length >= 2 ? [img] : [...scaleBar.pts, img];
			if (scaleBar.pts.length === 2) {
				scanTarget = 'pin';
				panelOpen = true;
				tick().then(() => scaleInput?.focus());
				applyScale();
			}
			return;
		}
		if (scanTarget === 'north') {
			north = north.length >= 2 ? [img] : [...north, img];
			if (north.length === 2) {
				scanTarget = 'pin';
				applyNorth();
			}
			return;
		}
		addImgPin(img);
	}
	/** The sheet's move-turn-scale now (from its corners). */
	function sheetPose(): { s: number; th: number } | null {
		if (!scan) return null;
		const box: XY[] = [[0, 0], [scan.width, 0], [scan.width, scan.height], [0, scan.height]];
		const f = fit(box, scan.corners.map((c) => toMerc(c)), 'affine');
		return f ? poseOf(f.m) : null;
	}
	/** Turn and/or scale the sheet about its middle (before there are pins to do it about). */
	function reposeSheet(s: number | null, th: number | null) {
		if (!scan) return;
		const now = sheetPose();
		if (!now) return;
		const mid: XY = [scan.width / 2, scan.height / 2];
		const m = placeAt(mid, toMerc(centroid(scan.corners)), s ?? now.s, th ?? now.th);
		setCorners(cornersFor({ m }, scan.width, scan.height));
		placeMarkers();
	}
	/** The scale bar was drawn or its length changed: with no pins yet, size the sheet by it. */
	function applyScale() {
		if (metresPerPx && !pairs.length) reposeSheet(metresPerPx * mercPerMetre(sheetLat), null);
	}
	/** The north arrow was drawn: turn the sheet so it points north (about the pin, if there's one). */
	function applyNorth() {
		if (northTh == null) return;
		if (pinFit?.kind === 'one') turnTh = northTh;
		else if (!pairs.length) reposeSheet(null, northTh);
	}
	/** ⟲ ⟳ and Flip with one pin: turn the sheet about it. */
	function turnBy(deg: number) {
		turnTh += (deg * Math.PI) / 180;
	}
	function scaleBy(k: number) {
		if (oneScale) oneScale *= k;
	}
	function clearScaleBar() {
		scaleBar = { pts: [], length: null, unit: scaleBar.unit };
		if (scanTarget === 'scale') scanTarget = 'pin';
	}
	function clearNorth() {
		north = [];
		if (scanTarget === 'north') scanTarget = 'pin';
	}

	function addImgPin(img: XY) {
		const p = pins.find((x) => !x.img);
		if (p) p.img = img;
		else pins.push({ id: ++pinSeq, img, map: null });
	}
	function addMapPin(ll: XY) {
		const p = pins.find((x) => !x.map);
		if (p) {
			p.map = ll;
			p.label = undefined;
		} else pins.push({ id: ++pinSeq, img: null, map: ll });
	}
	function moveImgPin(id: number, img: XY) {
		const p = pins.find((x) => x.id === id);
		if (p) p.img = img;
	}
	function removePin(id: number) {
		pins = pins.filter((p) => p.id !== id);
		if (!pins.length) pinSeq = 0;
		if (crossPin === id) crossPin = null;
	}
	function clearPins() {
		pins = [];
		pinSeq = 0;
		oneScale = null;
		crossPin = null;
		crossHits = [];
	}
	/** A fresh sheet: no pins, scale bar or north arrow. */
	function resetAlignment() {
		clearPins();
		scaleBar = { pts: [], length: null, unit: scaleBar.unit };
		north = [];
		scanTarget = 'pin';
		turnTh = 0;
		fitChoice = 'auto';
		crossProblem = null;
	}

	// ---------------------------------------------------------------- pin a street corner by name
	// "Broadway & 5th Ave": the wiki's own streets first (in the sheet's year, by any name they had),
	// then today's streets from OpenStreetMap for the ones not mapped here.
	let crossQ = $state('');
	let crossBusy = $state(false);
	let crossHits = $state<CrossingHit[]>([]);
	let crossProblem = $state<string | null>(null);
	/** the pin the lookup placed (choosing another of the hits moves it) */
	let crossPin = $state<number | null>(null);
	async function findCrossing(e?: SubmitEvent, osm = false) {
		e?.preventDefault();
		const q = crossQ.trim();
		if (!q || !map || crossBusy) return;
		crossBusy = true;
		crossProblem = null;
		try {
			const c = map.getCenter();
			const params = new URLSearchParams({ q, near: `${c.lng.toFixed(6)},${c.lat.toFixed(6)}` });
			if (/^\d{4}$/.test(depictsYear)) params.set('at', depictsYear);
			if (osm) params.set('osm', '1');
			const r = await fetch(`/api/crossing?${params}`);
			if (!r.ok) throw new Error(r.status === 401 ? 'Sign in again to look up street corners.' : `The lookup failed (${r.status}).`);
			const j = (await r.json()) as { hits: CrossingHit[]; problem?: string | null };
			crossHits = j.hits;
			crossProblem = j.problem ?? null;
			if (!j.hits.length) return;
			// the pin waiting for its map spot, else a new one (its scan spot comes next); looking
			// again on today's map moves the same pin
			const waiting = pins.find((x) => x.img && !x.map) ?? pins.find((x) => !x.map);
			if (osm && crossPin != null && pins.some((x) => x.id === crossPin)) {
				// keep it
			} else if (waiting) crossPin = waiting.id;
			else {
				crossPin = ++pinSeq;
				pins.push({ id: crossPin, img: null, map: null });
			}
			useCrossing((osm && j.hits.find((h) => h.from === 'osm')) || j.hits[0]);
		} catch (err) {
			crossProblem = (err as Error).message;
		} finally {
			crossBusy = false;
		}
	}
	function useCrossing(h: CrossingHit) {
		const p = pins.find((x) => x.id === crossPin);
		if (!p || !map) return;
		p.map = [h.lon, h.lat];
		p.label = `${h.a} & ${h.b}`;
		placePins();
		map.flyTo({ center: [h.lon, h.lat], zoom: Math.max(map.getZoom(), 17), duration: 600 });
	}
	const crossFrom = (h: CrossingHit) =>
		h.from === 'osm' ? "today's map" : `the wiki's streets${h.then ? (depictsYear ? ` in ${depictsYear}` : '') : ' (another year)'}`;

	function placePins() {
		pinMarkers.forEach((m) => m.remove());
		pinMarkers = [];
		if (!pinning || !map || !maplibre) return;
		for (const p of pins) {
			if (!p.map) continue;
			const el = document.createElement('div');
			el.className = `handle pin${p.img ? '' : ' half'}`;
			el.textContent = String(p.id);
			el.title = `Pin ${p.id}${p.label ? ` (${p.label})` : ''}: drag to adjust`;
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

	// One pin: a ⟳ handle on the map turns the sheet about it
	let turnMarker: Marker | null = null;
	let turnDragging = false;
	function placeTurnHandle() {
		if (turnDragging) return;
		turnMarker?.remove();
		turnMarker = null;
		const f = pinFit;
		if (!pinning || !f || f.kind !== 'one' || !map || !maplibre || !scan) return;
		const p = pairs[0];
		const pm = toMerc(p.map!);
		// "up" the sheet from the pin, a third of the sheet away
		const at = apply(f.m, [p.img![0], p.img![1] - 0.33 * Math.hypot(scan.width, scan.height)]);
		const el = document.createElement('div');
		el.className = 'handle turn';
		el.textContent = '⟳';
		el.title = `Drag to turn the sheet about pin ${p.id}`;
		const m = new maplibre.Marker({ element: el, draggable: true }).setLngLat(fromMerc(at)).addTo(map);
		const a0 = Math.atan2(at[1] - pm[1], at[0] - pm[0]);
		const th0 = turnTh;
		m.on('dragstart', () => (turnDragging = true));
		m.on('drag', () => {
			const ll = m.getLngLat();
			const q = toMerc([ll.lng, ll.lat]);
			turnTh = th0 + Math.atan2(q[1] - pm[1], q[0] - pm[0]) - a0;
		});
		m.on('dragend', () => {
			turnDragging = false;
			placeTurnHandle();
		});
		turnMarker = m;
	}

	/** Save the alignment to a small file so the same scan can be re-aligned instantly next time. */
	function exportAlignment() {
		const a = alignmentNow();
		if (!a || !scan) return;
		const blob = new Blob([JSON.stringify(a, null, 2)], { type: 'application/json' });
		const link = document.createElement('a');
		link.href = URL.createObjectURL(blob);
		link.download = `${stemOf(scan.name)}.alignment.json`;
		link.click();
		URL.revokeObjectURL(link.href);
	}

	async function importAlignment(e: Event) {
		const input = e.currentTarget as HTMLInputElement;
		const file = input.files?.[0];
		input.value = '';
		if (!file || !scan) return;
		try {
			const j = JSON.parse(await file.text());
			const a = readAlignment(j && typeof j === 'object' ? (j.decaynet_book && Array.isArray(j.sheets) ? (j.sheets.find((s: { file?: string }) => s?.file === scan!.name) ?? null) : j) : null);
			if (!a) throw new Error('No corners for this scan in that file.');
			applyAlignment(a);
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
	const drawing = $derived(tool === 'trace');
	const effectiveMode = $derived(drawMode);
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
		// hidden shapes aren't snapped to (you hid them to draw something different)
		if (!showShapes) return [];
		const out: [number, number][] = [];
		const walk = (c: unknown): void => {
			if (Array.isArray(c) && typeof c[0] === 'number') out.push([c[0] as number, c[1] as number]);
			else if (Array.isArray(c)) c.forEach(walk);
		};
		for (const f of lastSnap.features) if (f.geometry && 'coordinates' in f.geometry) walk(f.geometry.coordinates);
		return out;
	}

	/** Show or hide the existing shapes and the base map (the View controls). */
	function applyView() {
		if (!map || !ready) return;
		for (const l of snapshotLayers('snapshot')) if (map.getLayer(l.id)) map.setLayoutProperty(l.id, 'visibility', showShapes ? 'visible' : 'none');
		if (map.getLayer('basemap')) map.setLayoutProperty('basemap', 'visibility', showBase ? 'visible' : 'none');
	}
	$effect(() => {
		void [showShapes, showBase];
		untrack(applyView);
	});
	// re-colour what's loaded when the colouring changes
	$effect(() => {
		const by = colorBy;
		untrack(() => {
			if (map && ready && map.getSource('snapshot')) (map.getSource('snapshot') as GeoJSONSource).setData(colorFeatures(lastSnap, by));
		});
	});

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
	// a freehand area: everything whose middle is inside it (a highway corridor, a cleared block)
	let lassoMode = $state(false);
	let lasso = $state<{ x: number; y: number }[] | null>(null);
	/** the source the selection's changes are cited to (kept for the next batch from the same aerial) */
	let bulkSource = $state('');
	let bulkDetail = $state('');
	let bulkResult = $state<{
		action: 'gone' | 'condition' | 'standing' | 'name' | 'notyet';
		at: string;
		status?: string;
		name?: string;
		starts?: string;
		done: number;
		skipped: { id: string; name: string; slug: string; reason: string }[];
		cited?: number;
	} | null>(null);
	/** what the selection gets: gone by a year, a condition from a year, still standing in a year, or a name from a year */
	let bulkMode = $state<'gone' | 'condition' | 'standing' | 'name'>('gone');
	let bulkName = $state('');
	/** "Gone by": demolished (it was there, now gone), or not there yet (built after this map) */
	let goneKind = $state<'demolished' | 'notyet'>('demolished');
	const notYet = $derived(bulkMode === 'gone' && goneKind === 'notyet');
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
		bulkNoteInput ??
			(bulkMode === 'condition'
				? `${statusLabel(bulkCondition)} in the ${bulkYear} aerial`
				: bulkMode === 'name'
					? `Named on the ${bulkYear} map`
					: `Not seen in the ${bulkYear} aerial`)
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
		if (moving) return;
		// hidden shapes can't be picked: the first pick shows them again
		if (!showShapes) return void (showShapes = true);
		const hit = snapshotHits([x - 5, y - 5], [x + 5, y + 5])[0];
		if (!hit) return;
		bulkResult = null;
		selected = selected.some((s) => s.id === hit.id) ? selected.filter((s) => s.id !== hit.id) : [...selected, hit];
	}
	/** Box: add everything inside it. */
	function pickBox(b: { x0: number; y0: number; x1: number; y1: number }) {
		if (moving) return;
		const hits = snapshotHits([Math.min(b.x0, b.x1), Math.min(b.y0, b.y1)], [Math.max(b.x0, b.x1), Math.max(b.y0, b.y1)]);
		const have = new Set(selected.map((s) => s.id));
		bulkResult = null;
		selected = [...selected, ...hits.filter((h) => !have.has(h.id))];
	}
	/** Lasso: add everything whose middle (as drawn now) is inside the outline. */
	function pickLasso(poly: { x: number; y: number }[]) {
		if (moving || !map || poly.length < 3) return;
		const xs = poly.map((p) => p.x);
		const ys = poly.map((p) => p.y);
		const inside = (x: number, y: number) => {
			let c = false;
			for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
				const a = poly[i];
				const b = poly[j];
				if (a.y > y !== b.y > y && x < ((b.x - a.x) * (y - a.y)) / (b.y - a.y) + a.x) c = !c;
			}
			return c;
		};
		const layers = snapshotLayers('snapshot').map((l) => l.id).filter((id) => map!.getLayer(id));
		// a page drawn across several tiles comes back in pieces: gather them before finding its middle
		const found = new Map<string, { p: Picked; sx: number; sy: number; n: number }>();
		const walk = (c: unknown, add: (xy: [number, number]) => void) => {
			if (Array.isArray(c) && typeof c[0] === 'number') add(c as [number, number]);
			else if (Array.isArray(c)) c.forEach((x) => walk(x, add));
		};
		for (const f of map.queryRenderedFeatures([[Math.min(...xs), Math.min(...ys)], [Math.max(...xs), Math.max(...ys)]], { layers })) {
			const p = pickedOf(f as unknown as { properties: Record<string, unknown> });
			if (!p) continue;
			const acc = found.get(p.id) ?? { p, sx: 0, sy: 0, n: 0 };
			walk((f.geometry as { coordinates?: unknown }).coordinates, (xy) => {
				const q = map!.project(xy);
				acc.sx += q.x;
				acc.sy += q.y;
				acc.n++;
			});
			found.set(p.id, acc);
		}
		const have = new Set(selected.map((s) => s.id));
		bulkResult = null;
		selected = [...selected, ...[...found.values()].filter((a) => a.n && !have.has(a.p.id) && inside(a.sx / a.n, a.sy / a.n)).map((a) => a.p)];
	}
	function stopSelecting() {
		selecting = false;
		boxMode = false;
		lassoMode = false;
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
	let highlighted: string[] = [];
	function highlight(ids: string[]) {
		if (!map || !ready) return;
		for (const id of highlighted) map.setFeatureState({ source: 'snapshot', id }, { selected: false });
		for (const id of ids) map.setFeatureState({ source: 'snapshot', id }, { selected: true });
		highlighted = ids;
	}

	// ---------------------------------------------------------------- move & turn the selection
	// For a sheet that was aligned a little off: the selected shapes (as shown in this year), and
	// the storefronts and suites inside them, shift and turn to where they belong. They're changed
	// in place, not given a new version: they were always there. (Redraw makes a new version.)
	type LL = [number, number];
	let moving = $state<{ from: LL; to: LL; angle: number } | null>(null);
	let moveSpaces = $state(true);
	let moveBusy = $state(false);
	let moveResult = $state<{ shapes: number; pages: number; spaces: number } | null>(null);
	// web mercator in degree units: angles there are angles on the map (and in EPSG:3857, as saved)
	const mercY = (lat: number) => (180 / Math.PI) * Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360));
	const unmercY = (y: number) => (360 / Math.PI) * Math.atan(Math.exp((y * Math.PI) / 180)) - 90;
	function moveFn(m: { from: LL; to: LL; angle: number }) {
		const a = (m.angle * Math.PI) / 180;
		const [c, sn] = [Math.cos(a), Math.sin(a)];
		const [ox, oy, tx, ty] = [m.from[0], mercY(m.from[1]), m.to[0], mercY(m.to[1])];
		return ([lon, lat]: LL): LL => {
			const x = lon - ox;
			const y = mercY(lat) - oy;
			return [+(tx + x * c - y * sn).toFixed(7), +unmercY(ty + x * sn + y * c).toFixed(7)];
		};
	}
	const mapCoords = (c: unknown, f: (p: LL) => LL): unknown =>
		Array.isArray(c) && typeof c[0] === 'number' ? f(c as LL) : Array.isArray(c) ? c.map((x) => mapCoords(x, f)) : c;
	const vertices = (g: GeoJSON.Geometry | null): LL[] => {
		const out: LL[] = [];
		const walk = (c: unknown): void => {
			if (Array.isArray(c) && typeof c[0] === 'number') out.push([c[0] as number, c[1] as number]);
			else if (Array.isArray(c)) c.forEach(walk);
		};
		if (g && 'coordinates' in g) walk(g.coordinates);
		return out;
	};
	const outerRings = (g: GeoJSON.Geometry): LL[][] =>
		g.type === 'Polygon' ? [g.coordinates[0] as LL[]] : g.type === 'MultiPolygon' ? g.coordinates.map((p) => p[0] as LL[]) : [];
	const inRing = ([x, y]: LL, ring: LL[]) => {
		let inside = false;
		for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
			const [xi, yi] = ring[i];
			const [xj, yj] = ring[j];
			if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
		}
		return inside;
	};
	const avg = (v: LL[]): LL => [v.reduce((a, p) => a + p[0], 0) / v.length, v.reduce((a, p) => a + p[1], 0) / v.length];
	/** The selected shapes on the map, and (to preview what the server moves with them) the spaces inside them. */
	function movingFeatures(): GeoJSON.Feature[] {
		const ids = new Set(selected.map((x) => x.id));
		const own = lastSnap.features.filter((f) => ids.has(String(f.properties?.id)));
		if (!moveSpaces) return own;
		const rings = own.flatMap((f) => (f.geometry ? outerRings(f.geometry) : []));
		const spaces = lastSnap.features.filter((f) => {
			if (ids.has(String(f.properties?.id)) || f.properties?.kind !== 'space' || !f.geometry) return false;
			const v = vertices(f.geometry);
			return v.length > 0 && rings.some((r) => inRing(avg(v), r));
		});
		return [...own, ...spaces];
	}
	function startMove() {
		const v = movingFeatures().flatMap((f) => vertices(f.geometry));
		if (!v.length) return;
		const c = avg(v);
		moveResult = null;
		bulkResult = null;
		moving = { from: c, to: c, angle: 0 };
	}
	const metresPerDeg = 111320;
	const moveSummary = $derived.by(() => {
		if (!moving) return '';
		const dx = (moving.to[0] - moving.from[0]) * metresPerDeg * Math.cos((moving.from[1] * Math.PI) / 180);
		const dy = (moving.to[1] - moving.from[1]) * metresPerDeg;
		const d = Math.hypot(dx, dy);
		const parts = [d < 0.05 ? 'not moved' : `moved ${d < 10 ? d.toFixed(1) : Math.round(d)} m`];
		if (moving.angle) parts.push(`turned ${Math.abs(moving.angle).toFixed(1)}° ${moving.angle > 0 ? 'left' : 'right'}`);
		return parts.join(' · ');
	});
	/** Nudge by metres (arrow keys) or turn by degrees (counter-clockwise positive). */
	function nudge(east: number, north: number) {
		if (!moving) return;
		const lat = moving.to[1];
		moving.to = [moving.to[0] + east / (metresPerDeg * Math.cos((lat * Math.PI) / 180)), lat + north / metresPerDeg];
	}
	function turn(deg: number) {
		if (moving) moving.angle = Math.round((moving.angle + deg) * 100) / 100;
	}
	function drawMoving() {
		if (!map || !ready) return;
		const src = map.getSource('moving') as GeoJSONSource | undefined;
		if (!src) return;
		if (!moving) return src.setData({ type: 'FeatureCollection', features: [] });
		const f = moveFn(moving);
		src.setData({
			type: 'FeatureCollection',
			features: movingFeatures().map((x) => ({ type: 'Feature', properties: {}, geometry: { ...x.geometry, coordinates: mapCoords((x.geometry as GeoJSON.Point).coordinates, f) } as GeoJSON.Geometry }))
		});
	}
	let moveHandle: Marker | undefined;
	let draggingMove = false;
	function syncMoveHandle() {
		if (!map || !maplibre || !ready) return;
		if (!moving) {
			moveHandle?.remove();
			moveHandle = undefined;
			return;
		}
		if (moveHandle) {
			if (!draggingMove) moveHandle.setLngLat(moving.to);
			return;
		}
		const el = document.createElement('div');
		el.className = 'handle move big';
		el.title = 'Drag to move the selected shapes';
		const h = new maplibre.Marker({ element: el, draggable: true }).setLngLat(moving.to).addTo(map);
		h.on('dragstart', () => (draggingMove = true));
		h.on('drag', () => {
			const ll = h.getLngLat();
			if (moving) moving.to = [ll.lng, ll.lat];
		});
		h.on('dragend', () => (draggingMove = false));
		moveHandle = h;
	}
	function afterMove() {
		moveBusy = true;
		return async ({ result, update }: { result: { type: string; data?: Record<string, unknown> }; update: (o?: { reset?: boolean }) => Promise<void> }) => {
			await update({ reset: false });
			moveBusy = false;
			if (result.type === 'success' && result.data?.moved) {
				moveResult = result.data.moved as typeof moveResult;
				moving = null;
				refreshKey++;
			}
		};
	}

	// ---------------------------------------------------------------- redraw from a year
	// One selected page: its shape as shown goes into Trace to be reshaped; saving ends the old
	// shape at the year and starts this one (a renovation, or a better map from then on).
	let redraw = $state<{ id: string; name: string; slug: string } | null>(null);
	let redrawAt = $state('');
	let redrawBusy = $state(false);
	let pickedCorner = $state<number | null>(null);
	function startRedraw() {
		const x = selected[0];
		if (!x) return;
		const feats = lastSnap.features.filter((f) => String(f.properties?.id) === x.id && f.geometry);
		const g =
			feats.find((f) => /Polygon/.test(f.geometry!.type))?.geometry ??
			feats.find((f) => /LineString/.test(f.geometry!.type))?.geometry ??
			feats[0]?.geometry;
		let start: LL[] = [];
		if (g?.type === 'Polygon' || g?.type === 'MultiPolygon') {
			drawMode = 'polygon';
			// a several-part outline starts from its biggest part
			const ring = outerRings(g).sort((a, b) => b.length - a.length)[0] ?? [];
			start = ring.slice(0, -1);
		} else if (g?.type === 'LineString' || g?.type === 'MultiLineString') {
			drawMode = 'line';
			start = g.type === 'LineString' ? (g.coordinates as LL[]) : ((g.coordinates[0] ?? []) as LL[]);
		} else if (g?.type === 'Point') {
			drawMode = 'point';
			start = [g.coordinates as LL];
		}
		redraw = { id: x.id, name: x.name, slug: x.slug };
		redrawAt = bulkYear;
		pickedCorner = null;
		selected = [];
		bulkResult = null;
		stopSelecting();
		tool = 'trace';
		pts = start.map(([a, b]) => [a, b]);
	}
	function removeCorner() {
		if (pickedCorner == null) return;
		const min = effectiveMode === 'polygon' ? 3 : effectiveMode === 'line' ? 2 : 1;
		if (pts.length <= min) return;
		pts = pts.filter((_, i) => i !== pickedCorner);
		pickedCorner = null;
	}
	function cancelRedraw() {
		redraw = null;
		pickedCorner = null;
		pts = [];
	}
	/** A click while redrawing adds a corner on the nearest side, not at the end. */
	function insertCorner(c: LL, at: { x: number; y: number }) {
		if (!map || effectiveMode === 'point' || pts.length < 2) return void (pts = effectiveMode === 'point' ? [c] : [...pts, c]);
		const scr = pts.map((p) => map!.project(p));
		const n = effectiveMode === 'polygon' ? scr.length : scr.length - 1;
		let best = Infinity;
		let after = pts.length - 1;
		for (let i = 0; i < n; i++) {
			const a = scr[i];
			const b = scr[(i + 1) % scr.length];
			const [dx, dy] = [b.x - a.x, b.y - a.y];
			const t = Math.max(0, Math.min(1, ((at.x - a.x) * dx + (at.y - a.y) * dy) / (dx * dx + dy * dy || 1)));
			const d = Math.hypot(a.x + t * dx - at.x, a.y + t * dy - at.y);
			if (d < best) {
				best = d;
				after = i;
			}
		}
		pts = [...pts.slice(0, after + 1), c, ...pts.slice(after + 1)];
		pickedCorner = after + 1;
	}
	// a handle on each corner while redrawing: drag to reshape, tap to pick (then Remove corner)
	let cornerMarkers: Marker[] = [];
	let draggingCorner = -1;
	function syncCornerHandles() {
		if (!map || !maplibre || !ready) return;
		const want = redraw && tool === 'trace' ? pts.length : 0;
		if (cornerMarkers.length !== want) {
			cornerMarkers.forEach((m) => m.remove());
			cornerMarkers = [];
			for (let i = 0; i < want; i++) {
				const el = document.createElement('div');
				el.className = 'handle corner-pt';
				el.title = 'Drag to move this corner; tap to pick it';
				// a click right after a drag is the end of the drag, not a pick
				let draggedAt = 0;
				el.addEventListener('click', (ev) => {
					ev.stopPropagation();
					if (Date.now() - draggedAt > 300) pickedCorner = pickedCorner === i ? null : i;
				});
				const mk = new maplibre.Marker({ element: el, draggable: true }).setLngLat(pts[i]).addTo(map);
				mk.on('dragstart', () => (draggingCorner = i));
				mk.on('drag', () => {
					const ll = mk.getLngLat();
					pts[i] = [+ll.lng.toFixed(7), +ll.lat.toFixed(7)];
				});
				mk.on('dragend', () => ((draggingCorner = -1), (draggedAt = Date.now())));
				cornerMarkers.push(mk);
			}
		} else cornerMarkers.forEach((m, i) => i !== draggingCorner && m.setLngLat(pts[i]));
		cornerMarkers.forEach((m, i) => m.getElement().classList.toggle('picked', i === pickedCorner));
	}
	function afterRedraw() {
		redrawBusy = true;
		return async ({ result, update }: { result: { type: string; data?: Record<string, unknown> }; update: (o?: { reset?: boolean }) => Promise<void> }) => {
			await update({ reset: false });
			redrawBusy = false;
			if (result.type === 'success' && result.data?.redrawn) {
				redraw = null;
				pickedCorner = null;
				pts = [];
				refreshKey++;
			}
		};
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
		(map.getSource('snapshot') as GeoJSONSource).setData(colorFeatures(lastSnap, colorBy));
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
			if (!(e.shiftKey || boxMode || lassoMode) || e.button !== 0) return;
			if ((e.target as HTMLElement).closest('.maplibregl-marker, .maplibregl-ctrl')) return;
			const r = mapEl.getBoundingClientRect();
			mm.dragPan.disable();
			if (lassoMode || (e.shiftKey && e.altKey)) {
				// Lasso: a freehand outline
				lasso = [{ x: e.clientX - r.left, y: e.clientY - r.top }];
				const moveLasso = (ev: PointerEvent) => {
					if (!lasso) return;
					const q = { x: ev.clientX - r.left, y: ev.clientY - r.top };
					const last = lasso[lasso.length - 1];
					if (Math.hypot(q.x - last.x, q.y - last.y) > 3) lasso = [...lasso, q];
				};
				const endLasso = () => {
					window.removeEventListener('pointermove', moveLasso);
					window.removeEventListener('pointerup', endLasso);
					window.removeEventListener('pointercancel', endLasso);
					mm.dragPan.enable();
					const l = lasso;
					lasso = null;
					if (l && l.length > 3) pickLasso(l);
				};
				window.addEventListener('pointermove', moveLasso);
				window.addEventListener('pointerup', endLasso);
				window.addEventListener('pointercancel', endLasso);
				return;
			}
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

			// the selection being moved: where it will go
			m.addSource('moving', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
			m.addLayer({ id: 'moving-fill', type: 'fill', source: 'moving', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': '#5fd0c4', 'fill-opacity': 0.25 } });
			m.addLayer({ id: 'moving-line', type: 'line', source: 'moving', filter: ['!=', ['geometry-type'], 'Point'], paint: { 'line-color': '#5fd0c4', 'line-width': 2, 'line-dasharray': [2, 1] } });
			m.addLayer({ id: 'moving-pt', type: 'circle', source: 'moving', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 5, 'circle-color': '#5fd0c4', 'circle-stroke-color': '#17130f', 'circle-stroke-width': 1.5 } });

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
				else if (redraw && tool === 'trace') insertCorner(c, e.point);
				else pts = effectiveMode === 'point' ? [c] : [...pts, c];
			});
			m.on('moveend', () => saveView({ center: [m.getCenter().lng, m.getCenter().lat], zoom: m.getZoom() }));
			m.on('move', () => top?.jumpTo({ center: m.getCenter(), zoom: m.getZoom(), bearing: m.getBearing(), pitch: m.getPitch() }));
			ready = true;
			applyOverlay();
			applyView();
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
		moveHandle?.remove();
		cornerMarkers.forEach((m) => m.remove());
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
		void [opacity, overlayHidden, scanOff];
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
	// Re-fit the sheet whenever the matched pins change (or, with one pin, its turn and scale)
	$effect(() => {
		const f = pinFit;
		if (!f) return;
		untrack(() => scan && setCorners(cornersFor(f, scan.width, scan.height)));
	});
	// The first pin: the sheet jumps to it, keeping its size and turn (until a scale bar, north arrow,
	// ⟲ ⟳ or a second pin say otherwise)
	$effect(() => {
		if (pairs.length !== 1 || fitKind !== 'one') {
			// back to one pin later: start again from where the sheet is then
			untrack(() => (oneScale = null));
			return;
		}
		untrack(() => {
			if (oneScale != null) return;
			const p = sheetPose();
			if (!p) return;
			oneScale = p.s;
			turnTh = p.th;
		});
	});
	$effect(() => {
		void [pinning, ready, pinFit];
		untrack(placeTurnHandle);
	});
	// the book's other sheets on the map
	$effect(() => {
		void [ready, showBook, current, tool, book.map((s) => `${s.id}:${s.thumb}:${s.aligned}:${s.alignment?.corners.flat().join()}`).join('|')];
		untrack(drawBook);
	});
	// Hide handles while drawing so clicks land on the map
	$effect(() => {
		if (tool === 'trace') aligning = false;
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
	$effect(() => {
		void [moving?.to, moving?.angle, moving?.from, moveSpaces, ready];
		untrack(() => {
			drawMoving();
			syncMoveHandle();
		});
	});
	// moving is about the selection: clearing it (or leaving select) stops
	$effect(() => {
		if (!selected.length) untrack(() => (moving = null));
	});
	$effect(() => {
		void [pts, redraw, tool, pickedCorner, ready];
		untrack(syncCornerHandles);
	});
	// leaving Trace drops a redraw in progress
	$effect(() => {
		if (tool !== 'trace') untrack(() => redraw && cancelRedraw());
	});
	const highlightIds = $derived(selected.map((x) => x.id));
	$effect(() => {
		const ids = highlightIds;
		untrack(() => highlight(ids));
	});
	$effect(() => {
		if (map) map.getCanvas().style.cursor = drawing || pinning || boxMode || lassoMode ? 'crosshair' : selecting ? 'pointer' : '';
	});

	function onkey(e: KeyboardEvent) {
		const t = e.target as HTMLElement;
		if (t.closest('input, textarea, select')) return;
		if (e.key === 'f' && !e.repeat) overlayHidden = true;
		if (e.key === 'h' && !e.repeat && !e.metaKey && !e.ctrlKey) showShapes = !showShapes;
		if (redraw && tool === 'trace' && pickedCorner != null && (e.key === 'Delete' || e.key === 'Backspace')) {
			e.preventDefault();
			return removeCorner();
		}
		if (drawing && e.key === 'Backspace') {
			e.preventDefault();
			pts = pts.slice(0, -1);
		}
		if (moving && !e.metaKey && !e.ctrlKey) {
			const step = e.shiftKey ? 2 : 0.25;
			const k = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, step], ArrowDown: [0, -step] }[e.key];
			if (k) {
				e.preventDefault();
				return nudge(k[0], k[1]);
			}
			if (e.key === '[' || e.key === ']') return turn((e.key === '[' ? 1 : -1) * (e.shiftKey ? 1 : 0.2));
			if (e.key === 'Escape') return void (moving = null);
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

<div class="wb" class:focus={focus || selectFocus} class:collapsed={narrow && panelHidden && !(focus || selectFocus)}>
	<aside class="panel">
		<div class="tabs">
			{#each TOOLS.filter((t) => t.ok) as t (t.id)}
				<button
					class:on={tool === t.id}
					onclick={() => {
						// a different tool starts a fresh drawing; the same tab (e.g. reopening the folded panel) keeps it
						if (tool !== t.id) ((tool = t.id), (pts = []));
						panelHidden = false;
					}}>{t.label}</button
				>
			{/each}
			{#if narrow}
				<button class="ghost panel-toggle" aria-expanded={!panelHidden} onclick={() => (panelHidden = !panelHidden)} title={panelHidden ? 'Show the tool panel' : 'Fold the panel away to see more map'}>
					{panelHidden ? 'Show ▾' : 'Hide ▴'}
				</button>
			{/if}
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
			{#if !scan && !tileUrl}
				<p class="hint">
					Lay a Sanborn sheet, plat, aerial or any scanned map over the data to line things up and trace from it.
					<strong>Scans stay in your browser for this session only</strong>: nothing is uploaded or published.
				</p>
			{/if}
			{#if scanError}<p class="notice error small">{scanError}</p>{/if}

			{#if !scan && !tileUrl}
				<h3>Open a scan</h3>
				<input type="file" multiple accept="image/png,image/jpeg,image/webp,image/gif,{JPEG2000_ACCEPT},{GEO_ACCEPT}" onchange={openScan} disabled={!!scanBusy} />
				{#if scanBusy}<p class="notice small">{scanBusy} Big sheets take a few seconds.</p>{/if}
				<p class="hint">
					It appears with four corner handles. Drag each corner onto the matching intersection, or pin street corners. PNG, JPEG, WebP, GIF, or JPEG 2000
					(<code>.jp2</code>, as the Library of Congress serves its Sanborn sheets).
				</p>
				<p class="hint">
					<strong>A whole volume?</strong> Pick all its sheets at once (or a zip of them): they're aligned one after another, and exported together as
					a georeferenced book. A book exported here opens again the same way.
				</p>
				<p class="hint">
					<strong>Already georeferenced?</strong> A GeoTIFF, an image picked together with its world file (<code>.tfw</code>, <code>.jgw</code>,
					<code>.j2w</code>…) and <code>.prj</code>, or a zip of them lands in place by itself. ECW and MrSID can't be read in a browser: convert them to
					GeoTIFF first.
				</p>
				{#if book.length}{@render bookUI()}{/if}
				<h3>…or a tile layer</h3>
				<p class="hint">Already georeferenced in Map Warper, Allmaps or similar? Paste its XYZ URL.</p>
				<div class="row">
					<input bind:value={tileInput} placeholder={'https://…/{z}/{x}/{y}.png'} style="flex: 1" />
					<button onclick={useTiles}>Use</button>
				</div>
			{:else}
				<div class="scan-card">
					<div class="scan-head">
						<strong class="scan-name">{scan ? scan.name : 'Tile layer'}</strong>
						<span class="session" title="Not uploaded or saved anywhere; gone when you close the page">this session only</span>
					</div>
					{#if scan && scanNote}<p class="hint scan-note">{scanNote}</p>{/if}
					{#if scan && scanGeo}
						<div class="geo">
							{#if scanGeo.crs && !scanGeo.problem}
								<p class="hint">
									Placed from its {scanGeo.geo.from}{scanGeo.guessed ? ' (the coordinate system is a guess: the one that puts it nearest here)' : ''}. Check it
									against the streets; <em>Align scan</em> to adjust.
								</p>
							{/if}
							{#if scanGeo.problem}<p class="notice small">{scanGeo.problem}</p>{/if}
							<label for="crs">Coordinate system</label>
							<select id="crs" value={crsPaste ? '' : (scanGeo.crs?.id ?? '')} onchange={(e) => chooseCrs((e.currentTarget as HTMLSelectElement).value)}>
								{#if !scanGeo.crs}<option value="" disabled>Pick one…</option>{/if}
								{#each CRS_PRESETS as c (c.id)}<option value={c.id}>{c.label}</option>{/each}
								{#if scanGeo.crs && !CRS_PRESETS.some((c) => c.id === scanGeo?.crs?.id)}<option value={scanGeo.crs.id}>{scanGeo.crs.label}</option>{/if}
								<option value="">Another: paste it…</option>
							</select>
							{#if crsPaste || (scanGeo.problem && !scanGeo.crs)}
								<textarea rows="3" bind:value={crsText} placeholder="An EPSG code, a PROJ.4 string (+proj=tmerc …) or a .prj file's WKT" aria-label="Coordinate system definition"></textarea>
								<button onclick={pasteCrs} disabled={!crsText.trim()}>Place it</button>
							{/if}
						</div>
					{/if}
					<div class="row scan-actions">
						{#if scan}
							{#if aligning}
								<button class="primary" onclick={() => (aligning = false)}>Finish aligning</button>
							{:else}
								<button onclick={() => ((aligning = true), (panelOpen = false))} title="Show the corner handles or pins to line the scan up">Align scan</button>
							{/if}
						{/if}
						{#if scan && book.length > 1}
							<button class:primary={!aligning} onclick={nextSheet} title="Keep this one where it is and open the next sheet to align">
								{nextUp ? 'Next sheet →' : 'Next sheet'}
							</button>
						{/if}
						<button class="ghost danger-btn" onclick={removeScan} title="Take the scan off the map">Remove {book.length > 1 ? 'sheet' : 'scan'}</button>
					</div>
				</div>
				{#if scan}{@render bookUI()}{/if}
				<div class="field">
					<label for="dy">Scan shows the year</label>
					<input id="dy" bind:value={depictsYear} placeholder="1925" oninput={() => /^\d{4}$/.test(depictsYear) && (year = Number(depictsYear))} />
					<p class="hint">Moves the time slider and pre-fills dates on traced shapes.</p>
				</div>

				{#if scan && aligning}
					<section class="aligning">
						<h3>Aligning</h3>
						<div class="field">
							<label for="op">Scan opacity {Math.round(opacity * 100)}%</label>
							<input id="op" type="range" min="0" max="1" step="0.05" bind:value={opacity} disabled={compare === 'swipe'} />
						</div>
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
								Click a recognisable spot on the scan (a street corner, a church, a bridge), then the same spot on the map, or
								<strong>type the street corner</strong> and it's found for you. <strong>One pin</strong> places the sheet there: set its size with the scale
								bar and turn it with the north arrow or ⟲ ⟳. <strong>2 pins</strong> move, turn and scale it into place; <strong>3 or more</strong> also correct
								stretch and skew. Spread them out toward the edges of the sheet. Drag any pin to fine-tune.
							</p>
							<p class="next">
								{#if scanTarget === 'scale'}
									<span class="sw scale"></span> Scale bar: click {scaleBar.pts.length === 1 ? 'its other end' : 'one end of it'} on the <strong>scan</strong>.
								{:else if scanTarget === 'north'}
									<span class="sw north"></span> North arrow: click its {north.length === 1 ? 'head' : 'tail'} on the <strong>scan</strong>.
								{:else if waitingMap != null && pins.find((p) => p.id === waitingMap)?.img}
									<span class="sw pin"></span> Pin {waitingMap}: now click the same spot on the <strong>map</strong>, or type the corner below.
								{:else if waitingImg != null}
									<span class="sw pin"></span> Pin {waitingImg}: now click that spot on the <strong>scan</strong>.
								{:else}
									<span class="sw pin"></span> Click a spot on the <strong>scan</strong> to place pin {pinSeq + 1}.
								{/if}
							</p>
							{@render crossingForm('xq')}
							{#if pins.length}
								<table class="pins">
									<thead><tr><th>#</th><th>Scan</th><th>Map</th><th title="Distance between where the fitted scan puts this spot and where you pinned it">Off by</th><th></th></tr></thead>
									<tbody>
										{#each pins as p (p.id)}
											<tr>
												<td><span class="pin-no">{p.id}</span></td>
												<td>{p.img ? '✓' : '—'}</td>
												<td class="pin-where" title={p.label ?? ''}>{p.map ? (p.label ?? '✓') : '—'}</td>
												<td class:bad={(residuals.get(p.id) ?? 0) > 2 * (rms ?? Infinity)}>
													{#if residuals.has(p.id)}{residuals.get(p.id)!.toFixed(1)} m{:else}<span class="muted">–</span>{/if}
												</td>
												<td><button class="ghost x" title="Remove pin {p.id}" onclick={() => removePin(p.id)}>✕</button></td>
											</tr>
										{/each}
									</tbody>
								</table>
							{/if}
							<p class="muted small fit-says">
								{#if pinFit?.kind === 'one'}
									Placed at pin {pairs[0].id}{metresPerPx ? ", at the scale bar's scale" : ', at its size so far'}. Turn it about the pin
									(<span class="sw turn">⟳</span> on the map, or the buttons){metresPerPx ? '' : ', and size it with the scale bar or − / +'}; a second pin settles both.
								{:else if pinFit}
									Fitted from {pairs.length} pins ({pinFit.kind === 'affine' ? 'stretch & skew' : pinFit.kind === 'rigid' ? "move & turn, at the scale bar's scale" : 'move, turn & scale'}){#if rms != null}{' · '}typical error {rms.toFixed(1)} m; a pin far off the rest is probably misplaced{/if}.
									{#if pairs.length === needPins(pinFit.kind)}Add another pin to check the fit.{/if}
									{#if northOff != null}<br /><strong>The pins turn the sheet {Math.abs(northOff).toFixed(1)}° {northOff > 0 ? 'clockwise' : 'anticlockwise'} of its north arrow</strong>: a pin may be on the wrong corner, or the arrow is off.{/if}
								{:else}
									{Math.max(0, needPins(fitKind) - pairs.length)} more matched pin{needPins(fitKind) - pairs.length === 1 ? '' : 's'} to place the sheet.
								{/if}
							</p>
							{#if pinFit?.kind === 'one'}
								<div class="row nudges">
									<button title="Turn a quarter anticlockwise" onclick={() => turnBy(-90)}>⟲ 90°</button>
									<button title="Turn anticlockwise" onclick={() => turnBy(-1)}>⟲ 1°</button>
									<button title="Turn anticlockwise a little" onclick={() => turnBy(-0.2)}>⟲ .2°</button>
									<button title="Turn clockwise a little" onclick={() => turnBy(0.2)}>⟳ .2°</button>
									<button title="Turn clockwise" onclick={() => turnBy(1)}>⟳ 1°</button>
									<button title="Turn a quarter clockwise" onclick={() => turnBy(90)}>⟳ 90°</button>
									<button title="Turn it right round (180°) about the pin" onclick={() => turnBy(180)}>Flip</button>
									{#if !metresPerPx}
										<button title="Shrink" onclick={() => scaleBy(0.98)}>− 2%</button>
										<button title="Grow" onclick={() => scaleBy(1.02)}>+ 2%</button>
									{/if}
								</div>
							{/if}
							<div class="sheet-marks">
								<div class="mark-row">
									<span class="sw scale"></span>
									<strong>Scale bar</strong>
									{#if scaleBar.pts.length === 2}
										<input
											class="scale-len"
											type="number"
											min="0"
											step="any"
											bind:this={scaleInput}
											bind:value={scaleBar.length}
											onchange={applyScale}
											placeholder="100"
											aria-label="How long the scale bar is"
										/>
										<select bind:value={scaleBar.unit} onchange={applyScale} aria-label="Unit">
											<option value="ft">feet</option>
											<option value="m">metres</option>
											<option value="yd">yards</option>
											<option value="ch">chains</option>
											<option value="rd">rods</option>
											<option value="mi">miles</option>
										</select>
										<button class="ghost x" title="Draw the scale bar again" onclick={() => ((scaleBar.pts = []), (scanTarget = 'scale'))}>↺</button>
										<button class="ghost x" title="Take the scale bar off" onclick={clearScaleBar}>✕</button>
									{:else}
										<button class="small-btn" class:on={scanTarget === 'scale'} onclick={() => ((scaleBar.pts = []), (scanTarget = scanTarget === 'scale' ? 'pin' : 'scale'))}>
											{scanTarget === 'scale' ? 'Cancel' : 'Draw it'}
										</button>
									{/if}
								</div>
								{#if scaleBar.pts.length === 2 && !metresPerPx}<p class="hint">How long is the line you drew? (A Sanborn bar is usually in feet.)</p>{/if}
								{#if metresPerPx && scan}
									<p class="muted small">{(metresPerPx * 100).toFixed(1)} cm a pixel: the sheet is {Math.round(scan.width * metresPerPx)} × {Math.round(scan.height * metresPerPx)} m.</p>
								{/if}
								<div class="mark-row">
									<span class="sw north"></span>
									<strong>North arrow</strong>
									{#if north.length === 2}
										<span class="muted small">turns the sheet north-up</span>
										<button class="ghost x" title="Draw the north arrow again" onclick={() => ((north = []), (scanTarget = 'north'))}>↺</button>
										<button class="ghost x" title="Take the north arrow off" onclick={clearNorth}>✕</button>
									{:else}
										<button class="small-btn" class:on={scanTarget === 'north'} onclick={() => ((north = []), (scanTarget = scanTarget === 'north' ? 'pin' : 'north'))}>
											{scanTarget === 'north' ? 'Cancel' : 'Draw it'}
										</button>
									{/if}
								</div>
								<p class="hint">Optional. Click both ends of the sheet's scale bar on the scan (or any length you know) and say how long it is; click the north arrow's tail, then its head.</p>
							</div>
							<div class="field">
								<label for="fk">Fit</label>
								<select id="fk" bind:value={fitChoice}>
									<option value="auto">Automatic</option>
									<option value="similarity">Move, turn &amp; scale only (2+ pins)</option>
									<option value="rigid" disabled={!metresPerPx}>Move &amp; turn at the scale bar's scale (2+ pins)</option>
									<option value="affine">Also stretch &amp; skew (3+ pins)</option>
								</select>
							</div>
							{#if pins.length}<button class="ghost" onclick={clearPins}>Clear pins</button>{/if}
						{/if}
						{#if narrow}
							<button class="primary" onclick={() => (panelOpen = false)}>Back to full-screen aligning</button>
						{/if}
					</section>
				{/if}
				{#if scan}
					<details class="align-file">
						<summary>Alignment file</summary>
					<div class="row">
						<button class="ghost" onclick={exportAlignment} title="Download the corner positions as a small JSON file">Save alignment file</button>
						<label class="btn ghost filebtn">
							Load alignment
							<input type="file" accept=".json,application/json" onchange={importAlignment} />
						</label>
					</div>
					<p class="hint">Alignment files keep your work between sessions; the scan itself never leaves your computer.</p>
					</details>
				{/if}
				{#if !(scan && aligning)}
					<button class="primary start-tracing" onclick={() => (tool = 'trace')}>Start tracing →</button>
					<p class="hint">Opacity, swipe and what's shown are under <strong>View</strong> on the map.</p>
				{/if}
			{/if}
		{/if}

		<!-- ======================= TRACE ======================= -->
		{#if tool === 'trace'}
			{#if !redraw}
			<div class="seg">
				{#each ['polygon', 'line', 'point'] as const as m (m)}
					<button class:on={drawMode === m} onclick={() => ((drawMode = m), (pts = []))}>{m}</button>
				{/each}
			</div>
			<p class="hint">
				{narrow ? 'Tap' : 'Click'} to add corners over the scan{showShapes ? '; they snap to existing shapes' : ''}. Drag the
				<span class="sw move"></span> handle to move the whole shape.
				{#if !narrow}<kbd>Backspace</kbd> undoes, <kbd>Esc</kbd> clears.{/if}
				{#if showShapes}<button class="link" onclick={() => (showShapes = false)}>Hide existing shapes</button> to trace without them in the way.{/if}
			</p>
			{/if}
			<div class="row draw-status">
				<span class="muted small">{pts.length} corner{pts.length === 1 ? '' : 's'}{geometry ? ' · ready to save' : ''}</span>
				<span class="spacer"></span>
				<button class="ghost small-btn" disabled={!pts.length} onclick={() => (pts = pts.slice(0, -1))}>Undo</button>
				<button class="ghost small-btn" disabled={!pts.length} onclick={() => (pts = [])}>Clear</button>
			</div>

			{#if redraw}
				<form method="post" action="?/redraw" class="stack redraw-box card" use:enhance={afterRedraw}>
					<input type="hidden" name="tool" value="trace" />
					<input type="hidden" name="entity_id" value={redraw.id} />
					<input type="hidden" name="geojson" value={geojsonText} />
					<div class="spread">
						<h3>Redrawing <a href="/e/{redraw.slug}" target="_blank" rel="noopener">{redraw.name}</a></h3>
						<button type="button" class="ghost small-btn" onclick={cancelRedraw}>Cancel</button>
					</div>
					<p class="hint">
						Its shape is loaded: drag a corner to move it, {narrow ? 'tap' : 'click'} beside a side to add one, or pick a corner and
						remove it. Saving ends the shape shown then and starts this one, up to when the old one would have ended. For a sheet that
						was simply misaligned, use Move instead: that fixes the shape where it always was.
					</p>
					{#if pickedCorner != null}
						<div class="row">
							<span class="muted small">Corner {pickedCorner + 1} picked</span>
							<button type="button" class="ghost small-btn" onclick={removeCorner}>Remove corner</button>
						</div>
					{/if}
					<div class="fields">
						<div>
							<label for="rd-at">New shape from</label>
							<input id="rd-at" name="at" bind:value={redrawAt} placeholder="1958 · May 1958" />
						</div>
						<div>
							<label for="rd-conf">Confidence</label>
							<select id="rd-conf" name="confidence">
								{#each CONFIDENCES as c (c)}<option selected={c === 'probable'}>{c}</option>{/each}
							</select>
						</div>
					</div>
					<div>
						<label for="rd-src">Source</label>
						<SourcePicker id="rd-src" name="source_id" sources={data.sources} allowNew={false} />
					</div>
					<div><label for="rd-note">Note</label><input id="rd-note" name="note" placeholder="Rear wing added · redrawn from the 1958 aerial" /></div>
					<button class="primary" disabled={!geometry || redrawBusy || !redrawAt.trim()}>
						{redrawBusy ? 'Saving…' : `Save new shape from ${redrawAt.trim() || '…'}`}
					</button>
				</form>
			{:else}
			<h3>Save to a page</h3>
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

			<details class="fold">
				<summary>Drawing style</summary>
				<div class="opacity">
					<div class="field">
						<label for="tsf">Shape fill {Math.round(shapeFill * 100)}%</label>
						<input id="tsf" type="range" min="0" max="1" step="0.05" bind:value={shapeFill} />
					</div>
					<div class="field">
						<label for="tsl">Shape outline {Math.round(shapeLine * 100)}%</label>
						<input id="tsl" type="range" min="0.1" max="1" step="0.05" bind:value={shapeLine} />
					</div>
				</div>
			</details>
			<details class="fold" open={kept.length > 0}>
				<summary>Export as GeoJSON instead{kept.length ? ` (${kept.length} kept)` : ''}</summary>
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

			</details>
		{/if}

		<!-- ======================= AREA ======================= -->
		<!-- ======================= IMPORT ======================= -->
		{#if tool === 'import'}
			<p class="hint">
				Bring in GIS data: building footprints, parcels, digitized street grids. Upload a GeoJSON FeatureCollection in lon/lat
				(EPSG:4326). Each feature becomes a page with a dated shape. For a list of businesses or people with addresses, use the
				<a href="/import/spreadsheet">spreadsheet import</a>.
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
			<div class="scanpane" class:await={pinStep.where === 'scan' || scanTarget !== 'pin'}>
				<ScanPinView
					url={scan.url}
					width={scan.width}
					height={scan.height}
					{pins}
					waiting={waitingImg != null && !(waitingMap != null && pins.find((p) => p.id === waitingMap)?.img) ? waitingImg : null}
					lines={scanLines}
					tip={scanTip}
					onpin={scanClick}
					onmove={moveImgPin}
				/>
			</div>
		{/if}
		<div class="mapwrap" class:await={pinning && pinStep.where === 'map' && scanTarget === 'pin'}>
			<div class="map" bind:this={mapEl}></div>
			<div class="top" bind:this={topEl} class:hidden={compare !== 'swipe' || !activeSource || scanOff} style:clip-path="inset(0 {100 - swipe * 100}% 0 0)"></div>
			{#if compare === 'swipe' && activeSource}
				<div class="swipe" style:left="{swipe * 100}%" onpointerdown={() => (dragging = true)} role="slider" aria-valuenow={Math.round(swipe * 100)} aria-label="Swipe position" tabindex="0">
					<span>⇔</span>
				</div>
			{/if}
			{#if scan && aligning}
				<div class="banner">
					{#if alignMode === 'pins'}
						Pinning: a spot on the scan, then the same spot here (or type the street corner)
					{:else}
						Aligning: drag the corners · lower the opacity to see streets beneath
					{/if}
				</div>
			{/if}
			<div class="map-tl">
				{#if can('edit_content')}
					<button
						class="chip select-btn"
						class:on={selecting}
						onclick={() => (selecting ? stopSelecting() : ((selecting = true), (aligning = false), (showShapes = true)))}
						title={narrow ? 'Tap buildings to select them for bulk edits' : 'Click buildings to select them for bulk edits (or Shift-click / Shift-drag any time)'}
					>
						{selecting ? 'Stop selecting' : selected.length ? `Select (${selected.length})` : 'Select'}
					</button>
				{/if}
				<!-- what the map shows, in every tool -->
				<button
					class="chip"
					class:off={!showShapes}
					aria-pressed={showShapes}
					onclick={() => (showShapes = !showShapes)}
					title="Show or hide the existing shapes (H): hide them to trace a new footprint without the old one in the way"
				>
					{@render eye(showShapes)} Shapes
				</button>
				{#if activeSource}
					<button class="chip" class:off={scanOff} aria-pressed={!scanOff} onclick={() => (scanOff = !scanOff)} title="Show or hide the scan (hold F to flicker it)">
						{@render eye(!scanOff)} Scan
					</button>
				{/if}
				<details class="viewmenu">
					<summary class="chip" title="Layers and opacity">View</summary>
					<div class="viewpanel">
						<label class="check"><input type="checkbox" bind:checked={showShapes} /> Existing shapes <kbd>H</kbd></label>
						<p class="hint">Hidden: only the base map and scan show, and new corners don't snap to the old shapes.</p>
						<div class="seg color-by" role="radiogroup" aria-label="Colour the shapes by">
							<button class:on={colorBy === 'condition'} role="radio" aria-checked={colorBy === 'condition'} onclick={() => (colorBy = 'condition')}>Condition</button>
							<button class:on={colorBy === 'article'} role="radio" aria-checked={colorBy === 'article'} onclick={() => (colorBy = 'article')}>Article status</button>
						</div>
						{#if colorBy === 'condition' && data.settings.unstated_color}
							<p class="hint"><span class="sw" style:background={data.settings.unstated_color}></span> No condition yet for {year}</p>
						{:else if colorBy === 'article'}
							<p class="hint legend-row">
								{#each data.vocab.articleStatuses as st (st.id)}<span><span class="sw" style:background={st.color}></span> {st.label}</span>{/each}
							</p>
						{/if}
						{#if activeSource}
							<label class="check"><input type="checkbox" checked={!scanOff} onchange={(e) => (scanOff = !e.currentTarget.checked)} /> Scan</label>
							<div class="field">
								<label for="vop">Scan opacity {compare === 'swipe' ? '(swipe)' : `${Math.round(opacity * 100)}%`}</label>
								<input id="vop" type="range" min="0" max="1" step="0.05" bind:value={opacity} disabled={compare === 'swipe' || scanOff} />
							</div>
							<div class="seg">
								<button class:on={compare === 'blend'} onclick={() => (compare = 'blend')}>Blend</button>
								<button class:on={compare === 'swipe'} onclick={() => (compare = 'swipe')}>Swipe</button>
							</div>
							<p class="hint">Hold <kbd>F</kbd> to flicker the scan.</p>
						{/if}
						<label class="check"><input type="checkbox" bind:checked={showBase} /> Base map</label>
					</div>
				</details>
			</div>
			{#if lasso && lasso.length > 1}
				<svg class="select-lasso" aria-hidden="true"><polygon points={lasso.map((q) => `${q.x},${q.y}`).join(' ')} /></svg>
			{/if}
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
				<YearSlider bind:year min={Math.min(data.minYear, data.settings.min_year)} max={data.maxYear} compact={narrow} keyboard={!moving} />
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
				<button class="primary" onclick={() => (aligning = false)}>Finish aligning</button>
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
					<span>
						{#if scanTarget !== 'pin'}{scanTip}{:else if pinStep.where === 'map'}Now tap the same spot on the <strong>map</strong> ↓, or type the corner{:else}Tap a recognisable spot on the <strong>scan</strong> ↑{/if}
					</span>
				</p>
				{#if pinStep.where === 'map' || crossHits.length}{@render crossingForm('xq-bar')}{/if}
				{#if pinFit?.kind === 'one'}
					<div class="bar-nudges">
						<button title="Turn a quarter anticlockwise" onclick={() => turnBy(-90)}>⟲ 90°</button>
						<button title="Turn anticlockwise" onclick={() => turnBy(-1)}>⟲ 1°</button>
						<button title="Turn clockwise" onclick={() => turnBy(1)}>⟳ 1°</button>
						<button title="Turn a quarter clockwise" onclick={() => turnBy(90)}>⟳ 90°</button>
						<button title="Turn it right round (180°) about the pin" onclick={() => turnBy(180)}>Flip</button>
					</div>
				{/if}
				<div class="bar-row">
					<span class="muted small">
						{#if pinFit?.kind === 'one'}1 pin{metresPerPx ? ' · scale bar' : ''}{:else if pinFit}{pairs.length} pins{#if rms != null} · typical error {rms.toFixed(1)} m{/if}{:else}{Math.max(0, needPins(fitKind) - pairs.length)} more matched pin{needPins(fitKind) - pairs.length === 1 ? '' : 's'}{/if}
					</span>
					<span class="spacer"></span>
					<button class="ghost" disabled={!pins.length} onclick={() => removePin(pins[pins.length - 1].id)}>Undo pin</button>
					<button class="ghost" disabled={!pins.length} onclick={clearPins}>Clear</button>
				</div>
			{/if}
			<button class="link more" onclick={() => (panelOpen = true)}>More options (scale bar, north arrow, fit, book, year…)</button>
		</div>
	{/if}
	{#if selectFocus}
		<div class="alignbar selectbar">{@render selectionUI()}</div>
	{/if}
</div>

{#snippet crossingForm(id: string)}
	<form class="crossing" onsubmit={(e) => findCrossing(e)}>
		<label for={id}>{pinStep.where === 'map' ? `Pin ${pinStep.id} is the corner of…` : 'Pin a street corner by name'}</label>
		<div class="row">
			<input {id} bind:value={crossQ} placeholder="Broadway & 5th Ave" autocomplete="off" />
			<button disabled={crossBusy || !crossQ.trim()}>{crossBusy ? 'Finding…' : 'Find'}</button>
		</div>
	</form>
	{#if crossProblem}<p class="notice small">{crossProblem}</p>{/if}
	{#if crossHits.length}
		{@const at = pins.find((p) => p.id === crossPin)?.map}
		<ul class="cross-hits">
			{#each crossHits as h, i (i)}
				<li>
					<button class="link" class:on={at?.[0] === h.lon && at?.[1] === h.lat} onclick={() => useCrossing(h)} title="Put pin {crossPin} here">
						{h.a} &amp; {h.b}
					</button>
					<span class="muted small">from {crossFrom(h)}{h.gap_m > 0 ? `, where they come within ${Math.round(h.gap_m)} m` : ''}</span>
				</li>
			{/each}
		</ul>
		{#if crossHits.every((h) => h.from === 'wiki')}
			<button class="link small" onclick={() => findCrossing(undefined, true)} disabled={crossBusy}>Not right? Look on today's map too</button>
		{/if}
	{/if}
{/snippet}

{#snippet bookUI()}
	<details class="book" open={book.length > 1}>
		<summary>Book: {book.length} sheet{book.length === 1 ? '' : 's'}{#if book.length}, {alignedCount} placed{/if}</summary>
		{#if book.length}
			<ol class="sheets">
				{#each book as s, i (s.id)}
					{@const placed = s.id === current ? scanAligned : s.aligned}
					<li class:current={s.id === current}>
						<span class="sheet-no">{i + 1}</span>
						{#if s.id === current}
							<strong class="sheet-name" title={s.name}>{s.name}</strong>
						{:else}
							<button class="link sheet-name" onclick={() => openSheet(s.id)} title="Open {s.name} to align it" disabled={!!scanBusy}>{s.name}</button>
						{/if}
						<span class="sheet-state" class:done={placed}>{s.id === current ? 'open' : placed ? '✓ placed' : 'to do'}</span>
						{#if s.id !== current}<button class="ghost x" title="Take {s.name} out of the book" onclick={() => removeSheet(s.id)}>✕</button>{/if}
					</li>
				{/each}
			</ol>
		{/if}
		<label class="btn ghost filebtn">
			Add sheets…
			<input type="file" multiple accept="image/png,image/jpeg,image/webp,image/gif,{JPEG2000_ACCEPT},{GEO_ACCEPT}" onchange={openScan} disabled={!!scanBusy} />
		</label>
		{#if bookNote}<p class="hint">{bookNote}</p>{/if}
		<label class="check"><input type="checkbox" bind:checked={showBook} /> Show the placed sheets on the map</label>
		<label class="check"><input type="checkbox" bind:checked={bookImages} /> Put the scans in the export too</label>
		<button onclick={exportBook} disabled={!!bookBusy || !book.length}>{bookBusy ?? 'Export the book (.zip)'}</button>
		<p class="hint">
			Each placed sheet gets a world file at the scan's full resolution and a <code>.prj</code> (Web Mercator, EPSG:3857), so QGIS or ArcGIS open the
			scans in place; plus its alignment file, <code>book.json</code> and <code>index.geojson</code> (the sheets' outlines). Open the zip here again (with
			the scans, if you left them out) to carry on.
		</p>
	</details>
{/snippet}

{#snippet eye(on: boolean)}
	<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true" class="eye">
		<path d="M2 12s3.6-6.5 10-6.5S22 12 22 12s-3.6 6.5-10 6.5S2 12 2 12z" fill="none" stroke="currentColor" stroke-width="2" />
		{#if on}<circle cx="12" cy="12" r="3" fill="currentColor" />{:else}<path d="M4 20 20 4" stroke="currentColor" stroke-width="2" />{/if}
	</svg>
{/snippet}

{#snippet selectionUI()}
	<div class="bar-row">
		<strong class="sel-count">{selected.length} selected</strong>
		<span class="spacer"></span>
		<button class="ghost small-btn" class:on={boxMode} onclick={() => ((boxMode = !boxMode), (lassoMode = false))} title="Drag a box to select everything in it">Box</button>
		<button class="ghost small-btn" class:on={lassoMode} onclick={() => ((lassoMode = !lassoMode), (boxMode = false))} title="Draw around an area (a highway corridor, a cleared block) to select everything in it">Lasso</button>
		{#if selected.length && can('manage_records')}
			<a
				class="btn ghost small-btn"
				href={`/admin/records?ids=${selected.filter((x) => !x.ghost).slice(0, 1000).map((x) => x.id).join(',')}&y=${year}&sort=west`}
				title="Edit these pages together in Admin › Records, as of {year}">Open in Records</a
			>
		{/if}
		{#if selected.length}<button class="ghost small-btn" onclick={() => ((selected = []), (bulkResult = null))}>Clear</button>{/if}
		<button class="ghost small-btn" onclick={() => ((selected = []), (bulkResult = null), stopSelecting())}>Stop selecting</button>
	</div>
	{#if form && form.tool === 'select' && 'error' in form && form.error}<p class="notice error small">{form.error}</p>{/if}
	{#if bulkResult}
		<div class="notice small {bulkResult.done ? 'ok' : 'error'}">
			{bulkResult.done
				? `${bulkResult.done} ${bulkResult.action === 'name' ? 'named' : 'marked'} ${
						bulkResult.action === 'gone'
							? `gone by ${bulkResult.at}`
							: bulkResult.action === 'condition'
								? `${statusLabel(bulkResult.status)} from ${bulkResult.at}`
								: bulkResult.action === 'name'
									? `“${bulkResult.name}” from ${bulkResult.at}`
									: bulkResult.action === 'notyet'
										? `not seen yet in ${bulkResult.at} (built from ${bulkResult.starts})`
										: `still standing in ${bulkResult.at}`
					}.`
				: 'Nothing changed.'}{bulkResult.cited ? ` Cited ${bulkResult.cited} new record${bulkResult.cited === 1 ? '' : 's'} to the source.` : ''}
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
			{narrow || selecting ? 'Tap' : 'Shift-click'} buildings to select them{boxMode ? ', or drag a box' : lassoMode ? ', or draw around an area' : narrow ? '; Box or Lasso selects a whole area' : ', Shift-drag a box, or Shift+Alt-drag a lasso around any area'}. Then mark
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
		{#if moveResult}
			<p class="notice ok small">
				Moved {moveResult.shapes} shape{moveResult.shapes === 1 ? '' : 's'}{moveResult.spaces
					? ` (with ${moveResult.spaces} interior space${moveResult.spaces === 1 ? '' : 's'})`
					: ''}.
			</p>
		{/if}
		{#if moving}
			<form method="post" action="?/moveShapes" class="move-box" use:enhance={afterMove}>
				<input type="hidden" name="tool" value="select" />
				{#each selected as x (x.id)}<input type="hidden" name="ids" value={x.id} />{/each}
				<input type="hidden" name="at" value={yearToDate(year)} />
				<input type="hidden" name="from_lon" value={moving.from[0]} />
				<input type="hidden" name="from_lat" value={moving.from[1]} />
				<input type="hidden" name="to_lon" value={moving.to[0]} />
				<input type="hidden" name="to_lat" value={moving.to[1]} />
				<input type="hidden" name="angle" value={moving.angle} />
				<div class="bar-row">
					<strong>Move &amp; turn</strong>
					<span class="muted small move-sum">{moveSummary}</span>
				</div>
				<p class="hint">
					Drag the <span class="sw grip">✥</span> handle{narrow ? '' : ' (or nudge with the arrow keys, Shift for bigger steps)'}; turn
					with the buttons{narrow ? '' : ' or [ and ]'}. The shapes shown in {year} move where they always were, with no new version.
				</p>
				<div class="row nudges">
					<button type="button" class="ghost small-btn" onclick={() => turn(1)} title="Turn 1° left">⟲ 1°</button>
					<button type="button" class="ghost small-btn" onclick={() => turn(0.2)} title="Turn 0.2° left">⟲ 0.2°</button>
					<button type="button" class="ghost small-btn" onclick={() => turn(-0.2)} title="Turn 0.2° right">⟳ 0.2°</button>
					<button type="button" class="ghost small-btn" onclick={() => turn(-1)} title="Turn 1° right">⟳ 1°</button>
					<button type="button" class="ghost small-btn" onclick={() => moving && (moving = { ...moving, to: moving.from, angle: 0 })}>Reset</button>
				</div>
				<label class="check small">
					<input type="checkbox" name="spaces" value="1" bind:checked={moveSpaces} /> Storefronts and suites inside them move too
				</label>
				<div class="row">
					<button class="primary" disabled={moveBusy || moveSummary === 'not moved'}>{moveBusy ? 'Moving…' : 'Save move'}</button>
					<button type="button" class="ghost" onclick={() => (moving = null)}>Cancel</button>
				</div>
			</form>
		{:else}
		<div class="row adjust">
			<button class="ghost small-btn" onclick={startMove} title="Drag (and turn) the selected shapes, e.g. traced from a sheet that was aligned a little off">✥ Move / turn</button>
			{#if selected.length === 1 && !selected[0].ghost}
				<button class="ghost small-btn" onclick={startRedraw} title="Reshape it: the shape shown in {bulkYear} ends then, the new one starts">✎ Redraw from {bulkYear}</button>
			{/if}
		</div>
		<form method="post" action={notYet ? '?/bulkNotYet' : bulkMode === 'gone' ? '?/bulkGone' : bulkMode === 'condition' ? '?/bulkCondition' : bulkMode === 'name' ? '?/bulkName' : '?/bulkStanding'} class="bulk" use:enhance={afterBulk}>
			<input type="hidden" name="tool" value="select" />
			{#each selected as x (x.id)}<input type="hidden" name="ids" value={x.id} />{/each}
			<div class="seg bulk-mode" role="radiogroup" aria-label="What to record">
				<button type="button" class:on={bulkMode === 'gone'} onclick={() => ((bulkMode = 'gone'), (bulkNoteInput = null))}>Gone by</button>
				<button type="button" class:on={bulkMode === 'condition'} onclick={() => ((bulkMode = 'condition'), (bulkNoteInput = null))}>Condition from</button>
				<button type="button" class:on={bulkMode === 'standing'} onclick={() => (bulkMode = 'standing')}>Still standing in</button>
				<button type="button" class:on={bulkMode === 'name'} onclick={() => ((bulkMode = 'name'), (bulkNoteInput = null))}>Name from</button>
			</div>
			{#if bulkMode === 'gone'}
				<div class="gone-kind" role="radiogroup" aria-label="Why it isn't on the map">
					<span class="why">It's missing because it's</span>
					<button type="button" role="radio" aria-checked={goneKind === 'demolished'} class:on={goneKind === 'demolished'} onclick={() => (goneKind = 'demolished')}>Demolished here</button>
					<button type="button" role="radio" aria-checked={goneKind === 'notyet'} class:on={goneKind === 'notyet'} onclick={() => (goneKind = 'notyet')}>Not seen yet</button>
				</div>
			{/if}
			<div class="bulk-fields">
				<label>
					<span>{notYet ? 'Not seen in' : bulkMode === 'gone' ? 'Gone by' : bulkMode === 'condition' || bulkMode === 'name' ? 'From' : 'Standing in'}</span>
					<input name="at" value={bulkYear} oninput={(e) => (bulkYearInput = e.currentTarget.value)} placeholder="1958 · May 1958 · 1950s" title="A year, a month, a day, or a decade" />
				</label>
				{#if bulkMode === 'gone' && !notYet}
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
				{:else if bulkMode === 'name'}
					<label class="grow">
						<span>Name</span>
						<input name="name" bind:value={bulkName} placeholder={selected.length === 1 ? selected[0].name : 'Gary Hotel'} required />
					</label>
				{/if}
			</div>
			<div class="bulk-source">
				<span class="lbl">Citing</span>
				<SourcePicker name="source_id" sources={data.sources} bind:value={bulkSource} allowNew={false} noneLabel="Uncited" placeholder="The aerial or map you're working from…" />
				<input name="source_detail" bind:value={bulkDetail} placeholder="frame, sheet, page" aria-label="Where in it" />
			</div>
			{#if bulkMode !== 'standing' && !notYet}
				<label class="bulk-note">
					<span>Note</span>
					<input name="note" value={bulkNote} oninput={(e) => (bulkNoteInput = e.currentTarget.value)} />
				</label>
			{/if}
			<button class="primary" disabled={bulkBusy || (bulkMode === 'name' && !bulkName.trim())}>
				{notYet
					? `Mark ${selected.length} not seen yet in ${bulkYear}`
					: bulkMode === 'gone'
					? `Mark ${selected.length} gone by ${bulkYear}`
					: bulkMode === 'condition'
						? `Mark ${selected.length} ${statusLabel(bulkCondition)} from ${bulkYear}`
						: bulkMode === 'name'
							? `Name ${selected.length === 1 ? 'it' : selected.length} “${bulkName.replace(/\s+/g, ' ').trim() || '…'}” from ${bulkYear}`
							: `Mark ${selected.length} still standing in ${bulkYear}`}
			</button>
			<p class="hint">
				{#if notYet}
					Not built yet then: each start moves to just after that year, with what began with it. Pages that already start later, or
					with something recorded before then, are skipped.
				{:else if bulkMode === 'gone'}
					Ends each lifespan then, closes what was still running, and adds the condition (marked approximate). Pages with facts after
					that year are skipped.
				{:else if bulkMode === 'condition'}
					Starts the condition then (approximate), up to the next recorded one; what's recorded later, like a demolition, stays.
				{:else if bulkMode === 'name'}
					The map shows this name from then until the next recorded name; the name running then ends there. The page's title stays
					as it is.
				{:else}
					It was there then: a start after that year moves back to it, and ones marked gone by then reopen (a guessed demolition is
					removed).
				{/if}
			</p>
		</form>
		{/if}
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
	}
	/* polygon / line / point */
	.seg button {
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
	.check {
		display: flex;
		gap: 6px;
		align-items: center;
		margin: 0;
		color: var(--ink);
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
	.sw.grip {
		width: auto;
		height: auto;
		padding: 0 3px;
		background: #5fd0c4;
		border-radius: 50%;
		color: #17130f;
		font-size: 0.75rem;
		line-height: 1.3;
	}
	.move-box strong {
		white-space: nowrap;
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
	.sw.scale {
		height: 4px;
		width: 14px;
		background: #f0a030;
	}
	.sw.north {
		height: 4px;
		width: 14px;
		background: #5fd0e8;
	}
	.sw.turn {
		width: auto;
		height: auto;
		padding: 0 4px;
		background: #f0a030;
		border-radius: 50%;
		color: #17130f;
		font-size: 0.75rem;
		line-height: 1.3;
	}
	/* pin a street corner by name */
	.crossing {
		margin: 8px 0 4px;
	}
	.crossing label {
		display: block;
		font-size: 0.8rem;
		font-weight: 600;
		color: var(--ink-2);
		margin-bottom: 3px;
	}
	.crossing .row {
		gap: 4px;
		flex-wrap: nowrap;
	}
	.crossing input {
		flex: 1;
		min-width: 0;
	}
	.cross-hits {
		list-style: none;
		margin: 4px 0;
		padding: 0;
		font-size: 0.8rem;
	}
	.cross-hits li {
		padding: 2px 0;
	}
	.cross-hits button.on {
		font-weight: 700;
	}
	.cross-hits button.on::before {
		content: '● ';
		color: #e0574a;
	}
	td.pin-where {
		max-width: 9em;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.fit-says strong {
		color: #e0574a;
	}
	/* the sheet's scale bar and north arrow */
	.sheet-marks {
		margin: 8px 0;
		padding: 6px 8px;
		border: 1px solid var(--line);
		border-radius: 4px;
	}
	.mark-row {
		display: flex;
		align-items: center;
		gap: 6px;
		flex-wrap: wrap;
		min-height: 30px;
	}
	.mark-row strong {
		font-size: 0.85rem;
		margin-right: auto;
	}
	.scale-len {
		width: 6em;
	}
	/* the book's sheets */
	.book {
		margin: 10px 0;
		border-top: 1px solid var(--line);
		padding-top: 8px;
	}
	.book summary {
		cursor: pointer;
		color: var(--ink-2);
		font-weight: 600;
	}
	.book[open] summary {
		margin-bottom: 8px;
	}
	.book > button,
	.book > label {
		margin: 4px 0;
	}
	.sheets {
		list-style: none;
		margin: 0 0 6px;
		padding: 0;
		max-height: 14em;
		overflow-y: auto;
		font-size: 0.82rem;
	}
	.sheets li {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 2px 4px;
		border-radius: 3px;
	}
	.sheets li.current {
		background: rgba(242, 193, 78, 0.15);
	}
	.sheet-no {
		width: 1.6em;
		text-align: right;
		color: var(--ink-2);
		font: 600 0.75rem var(--mono);
	}
	.sheet-name {
		flex: 1;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		text-align: left;
	}
	.sheet-state {
		font-size: 0.75rem;
		color: var(--ink-2);
	}
	.sheet-state.done {
		color: #6fbf73;
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
		top: 50px; /* below the map's chips */
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
	:global(.handle.move.big) {
		display: grid;
		place-items: center;
		width: 30px;
		height: 30px;
		background: #5fd0c4;
	}
	:global(.handle.move.big)::after {
		content: '✥';
		color: #17130f;
		font-size: 17px;
		line-height: 1;
	}
	/* corners of a shape being redrawn */
	:global(.handle.corner-pt) {
		width: 12px;
		height: 12px;
		background: #f2c14e;
		border-radius: 50%;
	}
	:global(.handle.corner-pt.picked) {
		background: #e0574a;
		box-shadow:
			0 0 0 2px #17130f,
			0 0 0 5px #e0574a88;
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
	/* one pin: turn the sheet about it */
	:global(.handle.turn) {
		width: 26px;
		height: 26px;
		display: grid;
		place-items: center;
		background: #f0a030;
		color: #17130f;
		border-radius: 50%;
		font: 700 16px/1 var(--sans, sans-serif);
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
		:global(.handle.move.big) {
			width: 42px;
			height: 42px;
		}
		:global(.handle.corner-pt) {
			width: 22px;
			height: 22px;
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
	.map-tl {
		flex-wrap: wrap;
		right: 60px; /* clear of the zoom buttons */
		pointer-events: none;
	}
	.map-tl > * {
		pointer-events: auto;
	}
	.chip {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 5px 11px;
		font-size: 0.8rem;
		background: rgba(20, 17, 15, 0.9);
		border: 1px solid var(--line-2);
		border-radius: 999px;
		color: var(--ink);
		cursor: pointer;
		list-style: none;
	}
	.chip::-webkit-details-marker {
		display: none;
	}
	.chip.off {
		color: var(--muted);
		border-style: dashed;
	}
	.eye {
		flex: none;
	}
	/* the panel hangs from the chip row's left edge (the map's), so it stays on screen on a phone */
	.viewmenu {
		position: static;
	}
	.viewmenu[open] > .chip {
		border-color: var(--ink-2);
	}
	.viewpanel {
		position: absolute;
		top: calc(100% + 6px);
		left: 0;
		z-index: 6;
		width: min(270px, calc(100vw - 40px));
		display: grid;
		gap: 6px;
		padding: 10px 12px;
		background: var(--bg-2);
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
		font-size: 0.85rem;
	}
	.viewpanel .hint {
		margin: -2px 0 4px 22px;
	}
	.legend-row {
		display: flex;
		flex-wrap: wrap;
		gap: 2px 10px;
	}
	.viewpanel .field,
	.viewpanel .seg {
		margin: 0 0 0 22px;
	}
	.geo {
		display: grid;
		gap: 6px;
		margin: 6px 0;
	}
	.geo textarea {
		font-family: var(--mono);
		font-size: 0.78rem;
	}
	.scan-card {
		display: grid;
		gap: 8px;
		padding: 10px 12px;
		margin-bottom: 12px;
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		background: var(--panel);
	}
	.scan-head {
		display: flex;
		align-items: baseline;
		gap: 8px;
		flex-wrap: wrap;
	}
	.scan-name {
		overflow-wrap: anywhere;
	}
	.session {
		font-family: var(--mono);
		font-size: 0.68rem;
		color: var(--amber);
	}
	.scan-actions {
		gap: 6px;
		flex-wrap: wrap;
	}
	.danger-btn {
		color: var(--danger);
		border-color: color-mix(in srgb, var(--danger) 40%, transparent);
	}
	.danger-btn:hover {
		background: color-mix(in srgb, var(--danger) 12%, transparent);
	}
	.aligning {
		padding: 10px 0 4px;
		border-top: 1px solid var(--line);
	}
	.aligning h3 {
		margin-top: 0;
	}
	.align-file,
	.fold {
		margin: 10px 0;
		border-top: 1px solid var(--line);
		padding-top: 8px;
	}
	.align-file summary,
	.fold summary {
		cursor: pointer;
		color: var(--ink-2);
		font-weight: 600;
	}
	.align-file[open] summary,
	.fold[open] summary {
		margin-bottom: 8px;
	}
	.start-tracing {
		width: 100%;
		justify-content: center;
		margin-top: 6px;
	}
	.draw-status {
		align-items: center;
		gap: 6px;
		margin: 4px 0 10px;
	}
	.draw-status .spacer {
		flex: 1;
	}
	.select-btn.on,
	.small-btn.on {
		background: #f2c14e;
		border-color: #f2c14e;
		color: #17130f;
	}
	.select-lasso {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		pointer-events: none;
		z-index: 3;
	}
	.select-lasso polygon {
		fill: rgba(95, 208, 196, 0.15);
		stroke: #5fd0c4;
		stroke-width: 2;
		stroke-dasharray: 5 3;
	}
	.bulk-source {
		display: grid;
		grid-template-columns: auto 1fr 9rem;
		gap: 6px;
		align-items: center;
		margin: 6px 0;
	}
	.bulk-source .lbl {
		font-size: 0.8rem;
		color: var(--muted);
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
	.adjust {
		gap: 6px;
		margin: 4px 0 8px;
		flex-wrap: wrap;
	}
	.move-box {
		display: grid;
		gap: 6px;
		padding: 8px 10px;
		border: 1px solid #5fd0c4;
		border-radius: var(--radius);
	}
	.move-box .hint {
		margin: 0;
	}
	.move-sum {
		margin-left: auto;
		font-variant-numeric: tabular-nums;
	}
	.nudges {
		gap: 4px;
		flex-wrap: wrap;
	}
	.move-box .check {
		display: flex;
		gap: 6px;
		align-items: center;
		margin: 0;
		color: var(--ink-2);
	}
	.redraw-box {
		border-color: #f2c14e;
	}
	.redraw-box h3 {
		margin: 0;
	}
	/* a choice within "Gone by", not another mode */
	.gone-kind {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 4px 6px;
		margin: 0 0 0 4px;
		padding-left: 8px;
		border-left: 2px solid var(--amber);
	}
	.gone-kind .why {
		flex-basis: 100%;
		font-size: 0.72rem;
		color: var(--muted);
	}
	.gone-kind button {
		padding: 3px 10px;
		font-size: 0.75rem;
		border-radius: 999px;
	}
	.gone-kind button.on {
		background: var(--amber);
		border-color: var(--amber);
		color: #17130f;
	}
	/* four of them: two by two */
	.bulk-mode {
		display: grid;
		grid-template-columns: 1fr 1fr;
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
		/* the panel folded down to its tabs */
		.wb.collapsed {
			grid-template-rows: auto minmax(0, 1fr);
		}
		.wb.collapsed .panel {
			overflow: hidden;
			padding-bottom: 6px;
		}
		.wb.collapsed .panel > :not(.tabs) {
			display: none;
		}
		.wb.collapsed .tabs {
			margin-bottom: 0;
		}
		.panel-toggle {
			flex: 0 0 auto !important;
			padding: 6px 10px !important;
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
