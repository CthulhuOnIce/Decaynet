/*
 * Georeferenced scans for the workbench: GeoTIFFs, images with a world file (.tfw, .jgw, .j2w…)
 * and a .prj, or a zip of any of those. The image is decoded in the browser and placed where
 * its georeferencing says, by four corner pins, which can then be adjusted like any others.
 */
import type { ScanReply, ScanRequest, TiffGeo } from './scan.worker';
import { WANTED } from './shared';
import { toLngLat, type Crs } from './crs';
import { limits } from '$lib/jp2';

export { CRS_PRESETS, crsFromEpsg, crsFromText, guessCrs, type Crs } from './crs';

/** What the workbench's file picker takes, besides plain images and JPEG 2000. */
export const GEO_ACCEPT = '.tif,.tiff,image/tiff,.zip,application/zip,.json,.tfw,.tifw,.jgw,.jpgw,.j2w,.jp2w,.pgw,.pngw,.wld,.prj,.ecw,.sid';

/** pixel corner (i, j) at full resolution → map x / y in the image's coordinate system */
export type Transform = [number, number, number, number, number, number];

export interface Georef {
	transform: Transform;
	/** EPSG code from the GeoTIFF, if it named one */
	epsg: number | null;
	/** the .prj's text, or the GeoTIFF's description of its system */
	prj: string | null;
	citation: string | null;
	from: 'GeoTIFF' | 'world file';
}

let worker: Worker | null = null;
let seq = 0;
function ask<T extends ScanReply>(q: Omit<ScanRequest, 'id'>): Promise<T> {
	worker ??= new Worker(new URL('./scan.worker.ts', import.meta.url), { type: 'module' });
	const w = worker;
	const id = ++seq;
	return new Promise((resolve, reject) => {
		const done = () => {
			w.removeEventListener('message', onMessage);
			w.removeEventListener('error', onError);
		};
		const onMessage = (e: MessageEvent<ScanReply>) => {
			if (e.data.id !== id) return;
			done();
			if (!e.data.ok) reject(new Error(e.data.error));
			else resolve(e.data as T);
		};
		const onError = (e: ErrorEvent) => {
			done();
			worker = null;
			w.terminate();
			reject(new Error(e.message || 'The image reader failed to start.'));
		};
		w.addEventListener('message', onMessage);
		w.addEventListener('error', onError);
		w.postMessage({ ...q, id });
	});
}

const ext = (name: string) => (name.match(/\.([^.]+)$/)?.[1] ?? '').toLowerCase();
const stem = (name: string) => name.replace(/\.[^.]+$/, '').toLowerCase();
const WORLD = /^(tfw|tifw|tiffw|jgw|jpgw|jpegw|j2w|jp2w|pgw|pngw|wld)$/;
const IMAGE_RANK: Record<string, number> = { tif: 0, tiff: 0, jp2: 1, j2k: 1, jpg: 2, jpeg: 2, png: 2, webp: 3, gif: 3 };

async function isZip(f: Blob) {
	const b = new Uint8Array(await f.slice(0, 4).arrayBuffer());
	return b[0] === 0x50 && b[1] === 0x4b && b[2] === 0x03 && b[3] === 0x04;
}

/** By its first bytes: classic or BigTIFF, either byte order. */
export async function isTiff(f: Blob) {
	const b = new Uint8Array(await f.slice(0, 4).arrayBuffer());
	return (b[0] === 0x49 && b[1] === 0x49 && (b[2] === 0x2a || b[2] === 0x2b) && b[3] === 0) || (b[0] === 0x4d && b[1] === 0x4d && b[2] === 0 && (b[3] === 0x2a || b[3] === 0x2b));
}

export interface ScanFiles {
	image: File;
	/** six world-file numbers, if one came with it */
	world: number[] | null;
	prj: string | null;
	/** a Decaynet alignment file for it (its own, or its entry in a book's book.json) */
	alignment: Record<string, unknown> | null;
}

/** "sheet 2.jp2" before "sheet 10.jp2" */
const natural = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });

/**
 * The images to open, each with its georeferencing files, from what was picked: images with their
 * world files and .prj files, alignment files, a book's book.json, or zips of any of those. Each
 * image is a sheet (several of the same name, a .tif and its .jpg say, are one: the best is kept),
 * in the book's order, else by name. Explains formats the browser can't read (ECW, MrSID).
 */
export async function gatherScanSets(picked: File[]): Promise<{ sets: ScanFiles[]; note: string | null }> {
	let files = picked;
	const notes: string[] = [];
	const zip = await Promise.all(picked.map(isZip));
	if (zip.some(Boolean)) {
		const inner: File[] = [];
		const skipped: string[] = [];
		for (const [i, f] of picked.entries()) {
			if (!zip[i]) {
				inner.push(f);
				continue;
			}
			const r = await ask<Extract<ScanReply, { op: 'unzip' }>>({ op: 'unzip', file: f });
			// a folder in the zip doesn't matter: files are matched by name
			for (const x of r.files) inner.push(new File([x.data], x.name.replace(/^.*\//, '')));
			skipped.push(...r.skipped);
		}
		files = inner;
		const locked = skipped.filter((n) => /\.(ecw|sid)$/i.test(n));
		if (!files.some((f) => IMAGE_RANK[ext(f.name)] != null)) {
			if (locked.length) throw new Error(lockedFormat(locked[0]));
			throw new Error('There’s no image in that zip (TIFF, JPEG 2000, JPEG or PNG). A book’s zip without its scans needs the scans picked with it.');
		}
		if (locked.length) notes.push(`${locked.join(', ')} left out: browsers can't read ECW or MrSID.`);
	}
	const all = files.filter((f) => IMAGE_RANK[ext(f.name)] != null);
	const locked = files.find((f) => /^(ecw|sid)$/.test(ext(f.name)));
	if (!all.length) {
		if (locked) throw new Error(lockedFormat(locked.name));
		// an image picked with an unusual extension: try it as one
		if (files.length === 1 && !WANTED.test(files[0].name)) return { sets: [{ image: files[0], world: null, prj: null, alignment: null }], note: null };
		throw new Error('Pick an image (TIFF, JPEG 2000, JPEG or PNG), with its world file and .prj if it has them.');
	}
	// one image per name: the best kind, then the biggest
	const byStem = new Map<string, File>();
	for (const f of [...all].sort((a, b) => IMAGE_RANK[ext(a.name)] - IMAGE_RANK[ext(b.name)] || b.size - a.size))
		if (!byStem.has(stem(f.name))) byStem.set(stem(f.name), f);
	if (byStem.size < all.length) {
		const extra = all.length - byStem.size;
		notes.push(`${extra} image${extra > 1 ? 's' : ''} with the same name as another left out.`);
	}

	// alignment files: name.alignment.json, and a book's book.json (its sheets, in order)
	const alignments = new Map<string, Record<string, unknown>>();
	let order: string[] = [];
	for (const f of files.filter((f) => ext(f.name) === 'json')) {
		let j: unknown;
		try {
			j = JSON.parse(await f.text());
		} catch {
			continue;
		}
		if (!j || typeof j !== 'object') continue;
		const o = j as Record<string, unknown>;
		if (o.decaynet_book && Array.isArray(o.sheets)) {
			for (const s of o.sheets as Record<string, unknown>[]) if (typeof s?.file === 'string') alignments.set(stem(s.file), s);
			order = (o.sheets as Record<string, unknown>[]).map((s) => stem(String(s?.file ?? '')));
		} else if (o.decaynet_alignment) {
			const key = typeof o.file === 'string' ? stem(o.file) : f.name.toLowerCase().replace(/\.alignment\.json$/, '');
			alignments.set(key, o);
		}
	}

	const images = [...byStem.values()].sort((a, b) => {
		const ia = order.indexOf(stem(a.name));
		const ib = order.indexOf(stem(b.name));
		if (ia >= 0 || ib >= 0) return (ia < 0 ? Infinity : ia) - (ib < 0 ? Infinity : ib);
		return natural.compare(a.name, b.name);
	});
	const worlds = files.filter((f) => WORLD.test(ext(f.name)));
	const prjs = files.filter((f) => ext(f.name) === 'prj');
	const sets: ScanFiles[] = [];
	for (const image of images) {
		const same = (f: File) => stem(f.name) === stem(image.name) || stem(f.name) === image.name.toLowerCase();
		// a lone world file or .prj goes with a lone image whatever its name
		const worldFile = worlds.find(same) ?? (images.length === 1 && worlds.length === 1 ? worlds[0] : undefined);
		const prjFile = prjs.find(same) ?? (prjs.length === 1 ? prjs[0] : undefined);
		let world: number[] | null = null;
		if (worldFile) {
			const nums = (await worldFile.text()).split(/\s+/).filter(Boolean).map(Number);
			if (nums.length >= 6 && nums.slice(0, 6).every(Number.isFinite)) world = nums.slice(0, 6);
			else notes.push(`${worldFile.name} isn't a world file (six numbers): ignored.`);
		}
		sets.push({ image, world, prj: prjFile ? (await prjFile.text()).trim() : null, alignment: alignments.get(stem(image.name)) ?? null });
	}
	return { sets, note: notes.join(' ') || null };
}

const lockedFormat = (name: string) =>
	`${name} is ${/\.sid$/i.test(name) ? 'MrSID' : 'ECW'}, a format browsers can't read (it needs the maker's own licensed software). Convert it to a GeoTIFF on your computer, keeping its georeferencing: in QGIS, Raster › Conversion › Translate; or gdal_translate -of GTiff -co COMPRESS=JPEG "${name}" out.tif. Then open the .tif here.`;

/** World file numbers (A D B E C F, C/F the centre of the top-left pixel) → corner-based transform. */
export function worldTransform([A, D, B, E, C, F]: number[]): Transform {
	return [A, B, C - (A + B) / 2, D, E, F - (D + E) / 2];
}

export interface DecodedTiff {
	blob: Blob;
	width: number;
	height: number;
	fullWidth: number;
	fullHeight: number;
	geo: TiffGeo | null;
}

/** A TIFF / GeoTIFF as an image this browser can draw (reduced if it's bigger than that), with its georeferencing. */
export async function decodeTiff(file: Blob): Promise<DecodedTiff> {
	const r = await ask<Extract<ScanReply, { op: 'tiff' }>>({ op: 'tiff', file, ...limits() });
	let blob = r.blob;
	if (!blob && r.rgba) {
		const c = document.createElement('canvas');
		c.width = r.width;
		c.height = r.height;
		c.getContext('2d')!.putImageData(new ImageData(new Uint8ClampedArray(r.rgba), r.width, r.height), 0, 0);
		blob = await new Promise<Blob | null>((res) => c.toBlob(res, 'image/png'));
	}
	if (!blob) throw new Error('The decoded image could not be drawn.');
	return { blob, width: r.width, height: r.height, fullWidth: r.fullWidth, fullHeight: r.fullHeight, geo: r.geo };
}

/** Where a pixel corner of the full-resolution image is, in the image's coordinate system. */
const at = (t: Transform, i: number, j: number): [number, number] => [t[0] * i + t[1] * j + t[2], t[3] * i + t[4] * j + t[5]];

/** The image's centre, in its coordinate system (for guessing a system that isn't given). */
export const centreOf = (t: Transform, fullWidth: number, fullHeight: number) => at(t, fullWidth / 2, fullHeight / 2);

/**
 * Pins at the image's four corners, for the image as drawn (width × height,
 * maybe smaller than the file), placed where the coordinate system says. Null if they don't land
 * on Earth (the wrong system).
 */
export function georefPins(t: Transform, crs: Crs, size: { width: number; height: number; fullWidth: number; fullHeight: number }) {
	const sx = size.width / size.fullWidth;
	const sy = size.height / size.fullHeight;
	const out: { img: [number, number]; map: [number, number] }[] = [];
	for (const [fi, fj] of [
		[0, 0],
		[1, 0],
		[1, 1],
		[0, 1]
	]) {
		const i = fi * size.fullWidth;
		const j = fj * size.fullHeight;
		const ll = toLngLat(crs, at(t, i, j));
		if (!ll) return null;
		out.push({ img: [i * sx, j * sy], map: ll });
	}
	return out;
}
