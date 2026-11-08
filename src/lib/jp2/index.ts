/*
 * JPEG 2000 scans (the Library of Congress serves its Sanborn sheets as .jp2) for the workbench.
 * Most browsers can't show them, so they're decoded here, in a worker, into an ordinary image.
 * Nothing leaves the browser.
 */
import type { DecodeReply, DecodeRequest } from './decode.worker';

export const JPEG2000_ACCEPT = '.jp2,.j2k,.j2c,.jpx,.jpf,.jph,image/jp2,image/jpx,image/jpm';

/** By its first bytes: the JP2 signature box, or a bare codestream's SOC + SIZ markers. */
export async function isJpeg2000(file: Blob): Promise<boolean> {
	const b = new Uint8Array(await file.slice(0, 12).arrayBuffer());
	const jp2 = [0x00, 0x00, 0x00, 0x0c, 0x6a, 0x50, 0x20, 0x20, 0x0d, 0x0a, 0x87, 0x0a];
	if (b.length >= 12 && jp2.every((x, i) => b[i] === x)) return true;
	return b[0] === 0xff && b[1] === 0x4f && b[2] === 0xff && b[3] === 0x51;
}

export interface DecodedImage {
	blob: Blob;
	width: number;
	height: number;
	/** the image's own size; larger than width × height when it was decoded at a reduced resolution */
	fullWidth: number;
	fullHeight: number;
}

/** What this browser can draw: the GPU's texture limit (the map draws the scan as one) and a memory budget. */
export function limits() {
	let maxSide = 8192;
	try {
		const gl = document.createElement('canvas').getContext('webgl');
		if (gl) maxSide = Math.min(maxSide, gl.getParameter(gl.MAX_TEXTURE_SIZE) as number);
	} catch {
		/* keep the default */
	}
	// a computer takes a whole Library of Congress Sanborn sheet (6221 × 7677) at full resolution;
	// phones and machines with little memory get about 16 megapixels
	const mem = (navigator as Navigator & { deviceMemory?: number }).deviceMemory;
	const small = matchMedia('(pointer: coarse)').matches || (mem != null && mem <= 4);
	return { maxSide, maxPixels: small ? 16e6 : maxSide * maxSide };
}

let worker: Worker | null = null;
let seq = 0;

export function decodeJpeg2000(file: Blob): Promise<DecodedImage> {
	worker ??= new Worker(new URL('./decode.worker.ts', import.meta.url), { type: 'module' });
	const w = worker;
	const id = ++seq;
	return new Promise((resolve, reject) => {
		const onMessage = async (e: MessageEvent<DecodeReply>) => {
			if (e.data.id !== id) return;
			w.removeEventListener('message', onMessage);
			w.removeEventListener('error', onError);
			const r = e.data;
			if (!r.ok) return reject(new Error(`This JPEG 2000 file couldn't be read: ${r.error}.`));
			let blob = r.blob;
			if (!blob && r.rgba) {
				const c = document.createElement('canvas');
				c.width = r.width;
				c.height = r.height;
				c.getContext('2d')!.putImageData(new ImageData(new Uint8ClampedArray(r.rgba), r.width, r.height), 0, 0);
				blob = await new Promise<Blob | null>((res) => c.toBlob(res, 'image/jpeg', 0.95));
			}
			if (!blob) return reject(new Error('The decoded image could not be drawn.'));
			resolve({ blob, width: r.width, height: r.height, fullWidth: r.fullWidth, fullHeight: r.fullHeight });
		};
		const onError = (e: ErrorEvent) => {
			w.removeEventListener('message', onMessage);
			w.removeEventListener('error', onError);
			worker = null; // start a fresh one next time
			w.terminate();
			reject(new Error(e.message || 'The JPEG 2000 decoder failed to start.'));
		};
		w.addEventListener('message', onMessage);
		w.addEventListener('error', onError);
		file.arrayBuffer().then((data) => w.postMessage({ id, data, ...limits() } satisfies DecodeRequest, [data]), reject);
	});
}
