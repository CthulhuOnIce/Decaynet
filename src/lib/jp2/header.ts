/**
 * The image's size and how many halvings it holds, from the codestream's SIZ and COD markers
 * (the decoder only reports them after decoding). A .jp2 file wraps the codestream in a box.
 */
export function readHeader(bytes: Uint8Array) {
	const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	let cs = 0;
	let end = bytes.length; // where the codestream should end
	if (dv.getUint32(0) === 0x0c && dv.getUint32(4) === 0x6a502020) {
		// JP2: find the contiguous codestream box ('jp2c')
		let p = 0;
		cs = -1;
		while (p + 8 <= bytes.length) {
			let len = dv.getUint32(p);
			const type = dv.getUint32(p + 4);
			let head = 8;
			if (len === 1) {
				len = Number(dv.getBigUint64(p + 8));
				head = 16;
			} else if (len === 0) len = bytes.length - p;
			if (type === 0x6a703263) {
				cs = p + head;
				end = p + len;
				break;
			}
			if (len < head) break;
			p += len;
		}
		if (cs < 0) throw new Error('no image data (jp2c box) in the file');
	}
	if (dv.getUint16(cs) !== 0xff4f) throw new Error('not a JPEG 2000 codestream');
	let p = cs + 2;
	let size: { x0: number; y0: number; x1: number; y1: number } | null = null;
	let levels = 0;
	while (p + 4 <= bytes.length) {
		const marker = dv.getUint16(p);
		if (marker === 0xff90 || marker === 0xff93) break; // first tile: the main header is over
		const len = dv.getUint16(p + 2);
		if (marker === 0xff51) size = { x1: dv.getUint32(p + 6), y1: dv.getUint32(p + 10), x0: dv.getUint32(p + 14), y0: dv.getUint32(p + 18) };
		if (marker === 0xff52) levels = dv.getUint8(p + 9);
		p += 2 + len;
	}
	if (!size) throw new Error('no image size (SIZ) in the codestream');
	const at = (level: number) => {
		const f = 2 ** level;
		return { width: Math.ceil(size!.x1 / f) - Math.ceil(size!.x0 / f), height: Math.ceil(size!.y1 / f) - Math.ceil(size!.y0 / f) };
	};
	// a download cut short: the box says more than the file holds, or no end-of-codestream marker
	const truncated = end > bytes.length || dv.getUint16(Math.min(end, bytes.length) - 2) !== 0xffd9;
	return { ...at(0), levels, at, truncated };
}
