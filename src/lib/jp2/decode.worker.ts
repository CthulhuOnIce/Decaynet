/// <reference lib="webworker" />
/*
 * Decodes a JPEG 2000 image (a .jp2 file, or a bare .j2k codestream) off the main thread with
 * OpenJPEG compiled to WebAssembly, and hands back an ordinary image the browser can show.
 * Big sheets are decoded at a reduced resolution (JPEG 2000 stores halvings of the image), so
 * the browser never has to hold more than it can draw.
 */
import OpenJPEG from '@cornerstonejs/codec-openjpeg/decodewasmjs';
import wasmUrl from '@cornerstonejs/codec-openjpeg/decodewasm?url';
import { readHeader } from './header';

export interface DecodeRequest {
	id: number;
	data: ArrayBuffer;
	maxSide: number;
	maxPixels: number;
}
export type DecodeReply =
	| { id: number; ok: true; blob: Blob | null; rgba: ArrayBuffer | null; width: number; height: number; fullWidth: number; fullHeight: number; level: number }
	| { id: number; ok: false; error: string };

interface Decoder {
	getEncodedBuffer(n: number): Uint8Array;
	getFrameInfo(): { width: number; height: number; bitsPerSample: number; componentCount: number; isSigned: boolean };
	decode(): void;
	decodeSubResolution(level: number, layer: number): void;
	getDecodedBuffer(): Uint8Array;
	delete(): void;
}
type Lib = { J2KDecoder: new () => Decoder };

let lib: Promise<Lib> | null = null;
// the decoder logs every header it reads; keep the console quiet
const load = () => (lib ??= (OpenJPEG as unknown as (o: object) => Promise<Lib>)({ locateFile: () => wasmUrl, print: () => {}, printErr: () => {} }));

/** Any sample layout (grey, grey + alpha, RGB, RGBA; 8 or 16 bits; signed or not) as RGBA bytes. */
function toRGBA(buf: Uint8Array, w: number, h: number, comps: number, bits: number, signed: boolean): Uint8ClampedArray<ArrayBuffer> {
	const n = w * h;
	const wide = bits > 8;
	const src = wide ? new Uint16Array(buf.buffer, buf.byteOffset, n * comps) : buf;
	const shift = Math.max(0, bits - 8);
	const offset = signed ? 1 << (bits - 1) : 0;
	const v = (i: number) => ((src[i] + offset) & ((1 << bits) - 1)) >> shift;
	const out = new Uint8ClampedArray(n * 4);
	for (let p = 0, s = 0, o = 0; p < n; p++, s += comps, o += 4) {
		if (comps >= 3) {
			out[o] = v(s);
			out[o + 1] = v(s + 1);
			out[o + 2] = v(s + 2);
			out[o + 3] = comps >= 4 ? v(s + 3) : 255;
		} else {
			out[o] = out[o + 1] = out[o + 2] = v(s);
			out[o + 3] = comps === 2 ? v(s + 1) : 255;
		}
	}
	return out;
}

self.onmessage = async (e: MessageEvent<DecodeRequest>) => {
	const { id, data, maxSide, maxPixels } = e.data;
	const reply = (r: DecodeReply, transfer: Transferable[] = []) => (self as unknown as DedicatedWorkerGlobalScope).postMessage(r, transfer);
	let d: Decoder | null = null;
	try {
		const m = await load();
		d = new m.J2KDecoder();
		const bytes = new Uint8Array(data);
		const head = readHeader(bytes);
		// OpenJPEG would draw what's there and leave the rest blank or blurred: not something to trace from
		if (head.truncated) throw new Error('the file ends early, as if the download was cut short; download it again');
		// the smallest number of halvings that makes it fit
		let level = 0;
		let size = head.at(0);
		while (level < head.levels && (Math.max(size.width, size.height) > maxSide || size.width * size.height > maxPixels)) {
			level++;
			size = head.at(level);
		}
		d.getEncodedBuffer(bytes.length).set(bytes);
		if (level) d.decodeSubResolution(level, 0);
		else d.decode();
		const info = d.getFrameInfo();
		const { width, height } = size;
		const out = d.getDecodedBuffer();
		if (out.length !== width * height * info.componentCount * (info.bitsPerSample > 8 ? 2 : 1))
			throw new Error(`decoded ${out.length} bytes for a ${width} × ${height} image`);
		const rgba = toRGBA(out, width, height, info.componentCount, info.bitsPerSample, info.isSigned);
		d.delete();
		d = null;
		const base = { id, ok: true as const, width, height, fullWidth: head.width, fullHeight: head.height, level };
		if (typeof OffscreenCanvas !== 'undefined') {
			const c = new OffscreenCanvas(width, height);
			c.getContext('2d')!.putImageData(new ImageData(rgba, width, height), 0, 0);
			// JPEG at high quality keeps a scan's detail at a fraction of PNG's size and time; transparency needs PNG
			const alpha = info.componentCount === 2 || info.componentCount >= 4;
			const blob = await c.convertToBlob(alpha ? { type: 'image/png' } : { type: 'image/jpeg', quality: 0.95 });
			reply({ ...base, blob, rgba: null });
		} else {
			// no canvas in workers here: the page draws it
			reply({ ...base, blob: null, rgba: rgba.buffer }, [rgba.buffer]);
		}
	} catch (err) {
		try {
			d?.delete();
		} catch {
			/* already gone */
		}
		reply({ id, ok: false, error: err instanceof Error ? err.message : String(err) });
	}
};
