/// <reference lib="webworker" />
/*
 * Off the main thread, for the workbench's scans: unpack a zip (keeping only images and their
 * georeferencing files), and decode a TIFF / GeoTIFF into an image the browser can show, with
 * its georeferencing. Big rasters are read strip by strip at the size the browser can draw, so a
 * 20,000-pixel aerial never has to fit in memory whole. Nothing leaves the browser.
 */
import { unzipSync } from 'fflate';
import { fromBlob, type GeoTIFFImage } from 'geotiff';
import { WANTED } from './shared';

export type ScanRequest =
	| { id: number; op: 'unzip'; file: Blob }
	| { id: number; op: 'tiff'; file: Blob; maxSide: number; maxPixels: number };

export interface TiffGeo {
	/** pixel corner (i, j) at full resolution → x = t[0]·i + t[1]·j + t[2], y = t[3]·i + t[4]·j + t[5] */
	transform: [number, number, number, number, number, number];
	epsg: number | null;
	/** what the file calls its coordinate system */
	citation: string | null;
}

export type ScanReply =
	| { id: number; ok: true; op: 'unzip'; files: { name: string; data: ArrayBuffer }[]; skipped: string[] }
	| {
			id: number;
			ok: true;
			op: 'tiff';
			blob: Blob | null;
			rgba: ArrayBuffer | null;
			width: number;
			height: number;
			fullWidth: number;
			fullHeight: number;
			geo: TiffGeo | null;
	  }
	| { id: number; ok: false; error: string };


const post = (r: ScanReply, transfer: Transferable[] = []) => (self as unknown as DedicatedWorkerGlobalScope).postMessage(r, transfer);

self.onmessage = async (e: MessageEvent<ScanRequest>) => {
	const q = e.data;
	try {
		if (q.op === 'unzip') {
			const skipped: string[] = [];
			const out = unzipSync(new Uint8Array(await q.file.arrayBuffer()), {
				filter: (f) => {
					const base = f.name.split('/').pop() ?? '';
					if (f.name.startsWith('__MACOSX/') || base.startsWith('.')) return false;
					if (WANTED.test(base)) return true;
					if (base) skipped.push(base);
					return false;
				}
			});
			const files = Object.entries(out).map(([name, bytes]) => ({ name: name.split('/').pop() as string, data: bytes.buffer as ArrayBuffer }));
			post({ id: q.id, ok: true, op: 'unzip', files, skipped }, files.map((f) => f.data));
			return;
		}
		const r = await readTiff(q.file, q.maxSide, q.maxPixels);
		post({ id: q.id, ok: true, op: 'tiff', ...r }, r.rgba ? [r.rgba] : []);
	} catch (err) {
		post({ id: q.id, ok: false, error: (err as Error).message || String(err) });
	}
};

/** The georeferencing in the GeoTIFF tags, if any. */
function geoOf(img: GeoTIFFImage): TiffGeo | null {
	const keys = (img.getGeoKeys() ?? {}) as Record<string, unknown>;
	const fd = img.fileDirectory;
	const mt = fd.getValue('ModelTransformation') as number[] | undefined;
	let t: TiffGeo['transform'];
	if (mt && mt.length >= 16) {
		t = [mt[0], mt[1], mt[3], mt[4], mt[5], mt[7]];
	} else {
		let origin: number[];
		let res: number[];
		try {
			origin = img.getOrigin();
			res = img.getResolution();
		} catch {
			return null; // an ordinary TIFF scan: align it by hand
		}
		t = [res[0], 0, origin[0], 0, res[1], origin[1]];
	}
	// PixelIsPoint: the tie point is a pixel's centre, not its corner
	if (keys.GTRasterTypeGeoKey === 2) {
		t = [t[0], t[1], t[2] - (t[0] + t[1]) / 2, t[3], t[4], t[5] - (t[3] + t[4]) / 2];
	}
	const projected = Number(keys.ProjectedCSTypeGeoKey ?? keys.ProjectedCRSGeoKey);
	const geographic = Number(keys.GeographicTypeGeoKey ?? keys.GeodeticCRSGeoKey);
	const code = projected && projected !== 32767 ? projected : !projected && geographic && geographic !== 32767 ? geographic : null;
	const citation = [keys.PCSCitationGeoKey, keys.GTCitationGeoKey, keys.GeogCitationGeoKey].find((c) => typeof c === 'string' && c.trim()) as string | undefined;
	return { transform: t, epsg: code, citation: citation?.trim() ?? null };
}

async function readTiff(file: Blob, maxSide: number, maxPixels: number) {
	const tiff = await fromBlob(file);
	const base = await tiff.getImage(0);
	const fullWidth = base.getWidth();
	const fullHeight = base.getHeight();
	const scale = Math.min(1, maxSide / Math.max(fullWidth, fullHeight), Math.sqrt(maxPixels / (fullWidth * fullHeight)));
	const width = Math.max(1, Math.round(fullWidth * scale));
	const height = Math.max(1, Math.round(fullHeight * scale));

	// read from the smallest overview that's still at least that big (GeoTIFFs often carry them)
	let src = base;
	const count = await tiff.getImageCount();
	for (let i = 1; i < count; i++) {
		const o = await tiff.getImage(i);
		const ratio = o.getWidth() / fullWidth;
		if (Math.abs(o.getHeight() / fullHeight - ratio) > 0.02) continue; // a mask or another image, not an overview
		if (o.getWidth() >= width && o.getWidth() < src.getWidth()) src = o;
	}
	const sw = src.getWidth();
	const sh = src.getHeight();

	// 16-bit (or float) imagery: stretch to what's actually in it
	const bits = Math.max(...((src.fileDirectory.getValue('BitsPerSample') as number[] | undefined) ?? [8]));
	let max = 255;
	if (bits > 8) {
		const peek = (await src.readRGB({ width: Math.min(512, sw), height: Math.max(1, Math.round((Math.min(512, sw) * sh) / sw)), interleave: true })) as ArrayLike<number>;
		max = 1;
		for (let i = 0; i < peek.length; i++) if (peek[i] > max) max = peek[i];
	}
	const noData = base.getGDALNoData();

	const out = new Uint8ClampedArray(width * height * 4);
	// strips of about 32 MB of source pixels at a time
	const srcRowsPerStrip = Math.max(16, Math.floor((32e6 / 4) / sw));
	const outRowsPerStrip = Math.max(1, Math.floor((srcRowsPerStrip * height) / sh));
	for (let y0 = 0; y0 < height; y0 += outRowsPerStrip) {
		const y1 = Math.min(height, y0 + outRowsPerStrip);
		const sy0 = Math.floor((y0 * sh) / height);
		const sy1 = Math.max(sy0 + 1, Math.min(sh, Math.ceil((y1 * sh) / height)));
		const strip = (await src.readRGB({ window: [0, sy0, sw, sy1], width, height: y1 - y0, interleave: true, enableAlpha: true, resampleMethod: 'bilinear' })) as ArrayLike<number> & {
			width: number;
			height: number;
		};
		const ch = Math.round(strip.length / (width * (y1 - y0)));
		const k = 255 / max;
		for (let p = 0, n = width * (y1 - y0); p < n; p++) {
			const o = (y0 * width + p) * 4;
			const r = strip[p * ch];
			const g = ch >= 3 ? strip[p * ch + 1] : r;
			const b = ch >= 3 ? strip[p * ch + 2] : r;
			out[o] = r * k;
			out[o + 1] = g * k;
			out[o + 2] = b * k;
			out[o + 3] = ch === 4 || ch === 2 ? strip[p * ch + ch - 1] * k : noData != null && r === noData && g === noData && b === noData ? 0 : 255;
		}
	}
	const geo = geoOf(base);
	const hasAlpha = (() => {
		for (let i = 3; i < out.length; i += 4 * 97) if (out[i] < 255) return true;
		return false;
	})();
	let blob: Blob | null = null;
	if (typeof OffscreenCanvas !== 'undefined') {
		const c = new OffscreenCanvas(width, height);
		c.getContext('2d')!.putImageData(new ImageData(out, width, height), 0, 0);
		blob = await c.convertToBlob(hasAlpha ? { type: 'image/png' } : { type: 'image/jpeg', quality: 0.92 });
	}
	return { blob, rgba: blob ? null : (out.buffer as ArrayBuffer), width, height, fullWidth, fullHeight, geo };
}
