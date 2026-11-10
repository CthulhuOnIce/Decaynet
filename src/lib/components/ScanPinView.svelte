<!--
	Zoomable, pannable view of a scan for placing control-point pins.
	Click or tap (without dragging) to drop a pin (or a point of the scale bar or north arrow being
	drawn); drag a pin to move it; scroll or pinch to zoom; drag to pan (or, while cutting out a
	sub-map, to draw a box or lasso round part of the sheet).
	Pin positions are in the image's natural pixel coordinates.
-->
<script lang="ts">
	import { onMount, untrack } from 'svelte';

	type XY = [number, number];
	interface Pin {
		id: number;
		img: XY | null;
		map: XY | null;
	}

	let {
		url,
		width,
		height,
		pins,
		waiting = null,
		lines = [],
		tip = null,
		boxing = false,
		lassoing = false,
		boxes = [],
		onpin,
		onmove,
		onbox,
		onlasso
	}: {
		url: string;
		width: number;
		height: number;
		pins: Pin[];
		/** Pin id that is waiting for its image point, highlighted in the status line. */
		waiting?: number | null;
		/** lines drawn on the scan (the scale bar, the north arrow): one or two points each */
		lines?: { id: string; kind: string; label: string; pts: XY[] }[];
		/** the status line, instead of the pin one */
		tip?: string | null;
		/** a drag draws a box (cutting out a sub-map) instead of panning */
		boxing?: boolean;
		/** clicks place the corners of an outline, a drag draws it freehand (cutting out a sub-map) */
		lassoing?: boolean;
		/** outlines to show: parts cut out (mask), the one being cut (draft) */
		boxes?: { pts: XY[]; kind: string }[];
		onpin: (img: XY) => void;
		onmove: (id: number, img: XY) => void;
		/** a box drawn while boxing: [x, y, width, height] in the image's pixels */
		onbox?: (r: [number, number, number, number]) => void;
		/** an outline closed while lassoing, in the image's pixels */
		onlasso?: (pts: XY[]) => void;
	} = $props();
	let boxDraft = $state<[number, number, number, number] | null>(null);
	// the lasso being drawn: its corners so far
	let lassoPts = $state<XY[]>([]);
	let lastClick = 0;
	$effect(() => {
		if (!lassoing) lassoPts = [];
	});
	/** how far apart two image points are on screen */
	const screenGap = (a: XY, b: XY) => Math.hypot(a[0] - b[0], a[1] - b[1]) * scale;
	function closeLasso() {
		const pts = lassoPts.map(round);
		lassoPts = [];
		if (pts.length >= 3) onlasso?.(pts);
	}

	let el: HTMLDivElement;
	let scale = $state(1);
	let tx = $state(0);
	let ty = $state(0);
	let fitted = false;

	function fitView() {
		if (!el) return;
		const { clientWidth: W, clientHeight: H } = el;
		if (!W || !H) return;
		// Compute from a local so this never reads `scale` (it runs inside an effect)
		const s = Math.min(W / width, H / height) * 0.95;
		scale = s;
		tx = (W - width * s) / 2;
		ty = (H - height * s) / 2;
		fitted = true;
	}

	onMount(() => {
		fitView();
		const ro = new ResizeObserver(() => !fitted && fitView());
		ro.observe(el);
		// Added by hand: Svelte's onwheel is passive, so preventDefault() there can't stop the page/browser zooming instead
		el.addEventListener('wheel', onwheel, { passive: false });
		return () => {
			ro.disconnect();
			el.removeEventListener('wheel', onwheel);
		};
	});
	// Re-fit only when a different scan is shown, never in response to zoom/pan changes
	$effect(() => {
		void [url, width, height];
		untrack(() => {
			fitted = false;
			fitView();
		});
	});

	const toImg = (cx: number, cy: number): XY => {
		const r = el.getBoundingClientRect();
		return [(cx - r.left - tx) / scale, (cy - r.top - ty) / scale];
	};
	/** an image point as an SVG point on screen */
	const sp = (q: XY) => `${tx + q[0] * scale},${ty + q[1] * scale}`;
	const inside = ([x, y]: XY) => x >= 0 && y >= 0 && x <= width && y <= height;
	const round = ([x, y]: XY): XY => [Math.round(x * 10) / 10, Math.round(y * 10) / 10];

	function onwheel(e: WheelEvent) {
		e.preventDefault();
		const r = el.getBoundingClientRect();
		const px = e.clientX - r.left;
		const py = e.clientY - r.top;
		const k = Math.exp(-e.deltaY * (e.deltaMode === 1 ? 0.05 : 0.0015));
		const next = Math.max(0.02, Math.min(40, scale * k));
		tx = px - ((px - tx) * next) / scale;
		ty = py - ((py - ty) * next) / scale;
		scale = next;
	}

	// Pan, or click-to-pin when the pointer barely moved; two fingers pinch-zoom
	let drag: { x: number; y: number; tx: number; ty: number; moved: boolean; pin: number | null; box: XY | null; lasso: { start: XY; fresh: boolean } | null } | null = null;
	const clampImg = ([x, y]: XY): XY => [Math.max(0, Math.min(width, x)), Math.max(0, Math.min(height, y))];
	const boxOf = (a: XY, b: XY): [number, number, number, number] => [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.abs(b[0] - a[0]), Math.abs(b[1] - a[1])];
	const fingers = new Map<number, { x: number; y: number }>();
	let pinch: { d: number; ix: number; iy: number; scale: number } | null = null;
	const midpoint = () => {
		const [a, b] = [...fingers.values()];
		const r = el.getBoundingClientRect();
		return { d: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)), x: (a.x + b.x) / 2 - r.left, y: (a.y + b.y) / 2 - r.top };
	};
	function down(e: PointerEvent, pin: number | null = null) {
		if (e.button !== 0) return;
		e.stopPropagation();
		el.setPointerCapture(e.pointerId);
		fingers.set(e.pointerId, { x: e.clientX, y: e.clientY });
		if (fingers.size === 2) {
			// a second finger: pinch around the midpoint (and never drop a pin)
			const m = midpoint();
			pinch = { d: m.d, ix: (m.x - tx) / scale, iy: (m.y - ty) / scale, scale };
			drag = null;
			return;
		}
		if (fingers.size > 2) return;
		const at = clampImg(toImg(e.clientX, e.clientY));
		drag = {
			x: e.clientX,
			y: e.clientY,
			tx,
			ty,
			moved: false,
			pin,
			box: boxing && pin == null ? at : null,
			lasso: lassoing && pin == null ? { start: at, fresh: !lassoPts.length } : null
		};
	}
	function move(e: PointerEvent) {
		if (fingers.has(e.pointerId)) fingers.set(e.pointerId, { x: e.clientX, y: e.clientY });
		if (pinch && fingers.size >= 2) {
			const m = midpoint();
			const next = Math.max(0.02, Math.min(40, (pinch.scale * m.d) / pinch.d));
			// keep the image spot that started under the fingers under them
			tx = m.x - pinch.ix * next;
			ty = m.y - pinch.iy * next;
			scale = next;
			return;
		}
		if (!drag) return;
		const dx = e.clientX - drag.x;
		const dy = e.clientY - drag.y;
		// a fingertip wobbles more than a mouse before a tap becomes a drag
		if (!drag.moved && Math.hypot(dx, dy) < (e.pointerType === 'touch' ? 9 : 4)) return;
		drag.moved = true;
		if (drag.box) {
			boxDraft = boxOf(drag.box, clampImg(toImg(e.clientX, e.clientY)));
			return;
		}
		if (drag.lasso) {
			// freehand: a point every few screen pixels
			const q = clampImg(toImg(e.clientX, e.clientY));
			if (!lassoPts.length) lassoPts = [drag.lasso.start];
			if (screenGap(q, lassoPts[lassoPts.length - 1]) >= 4) lassoPts = [...lassoPts, q];
			return;
		}
		if (drag.pin != null) {
			const p = toImg(e.clientX, e.clientY);
			onmove(drag.pin, round([Math.max(0, Math.min(width, p[0])), Math.max(0, Math.min(height, p[1]))]));
		} else {
			tx = drag.tx + dx;
			ty = drag.ty + dy;
		}
	}
	function up(e: PointerEvent) {
		fingers.delete(e.pointerId);
		if (pinch) {
			if (fingers.size < 2) pinch = null;
			drag = null;
			return;
		}
		if (!drag) return;
		const d = drag;
		drag = null;
		if (d.box) {
			const b = boxDraft;
			boxDraft = null;
			if (d.moved && b && b[2] >= 8 && b[3] >= 8) onbox?.(b.map(Math.round) as [number, number, number, number]);
			return;
		}
		if (d.lasso) {
			if (d.moved) {
				// a lasso drawn in one stroke closes when let go; a stroke added to clicked corners
				// closes if it ends back at the first one
				if (d.lasso.fresh || (lassoPts.length >= 3 && screenGap(lassoPts[lassoPts.length - 1], lassoPts[0]) < 12)) closeLasso();
				return;
			}
			const q = clampImg(toImg(e.clientX, e.clientY));
			const now = Date.now();
			const n = lassoPts.length;
			// click the first corner again (or double-click) to close it
			if (n >= 3 && screenGap(q, lassoPts[0]) < 12) closeLasso();
			else if (n >= 3 && now - lastClick < 400 && screenGap(q, lassoPts[n - 1]) < 8) closeLasso();
			else if (!n || screenGap(q, lassoPts[n - 1]) >= 3) lassoPts = [...lassoPts, q];
			lastClick = now;
			return;
		}
		if (d.moved || d.pin != null) return;
		const p = toImg(e.clientX, e.clientY);
		if (inside(p)) onpin(round(p));
	}

	function zoomBy(k: number) {
		const { clientWidth: W, clientHeight: H } = el;
		const next = Math.max(0.02, Math.min(40, scale * k));
		tx = W / 2 - ((W / 2 - tx) * next) / scale;
		ty = H / 2 - ((H / 2 - ty) * next) / scale;
		scale = next;
	}
</script>

<div
	class="view"
	bind:this={el}
	onpointerdown={(e) => down(e)}
	onpointermove={move}
	onpointerup={up}
	onpointercancel={(e) => {
		fingers.delete(e.pointerId);
		pinch = null;
		drag = null;
		boxDraft = null;
	}}
	role="application"
	aria-label="Scan: click or tap to place a pin; pinch or scroll to zoom"
>
	<img src={url} alt="" draggable="false" style:width="{width * scale}px" style:height="{height * scale}px" style:transform="translate({tx}px, {ty}px)" />
	{#if lines.length}
		<svg class="lines" aria-hidden="true">
			<defs>
				<marker id="scan-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
					<path d="M0 0 10 5 0 10z" fill="#5fd0e8" />
				</marker>
			</defs>
			{#each lines as l (l.id)}
				<g class={l.kind}>
					{#if l.pts.length === 2}
						<line
							x1={tx + l.pts[0][0] * scale}
							y1={ty + l.pts[0][1] * scale}
							x2={tx + l.pts[1][0] * scale}
							y2={ty + l.pts[1][1] * scale}
							marker-end={l.kind === 'north' ? 'url(#scan-arrow)' : undefined}
						/>
					{/if}
					{#each l.pts as q, i (i)}<circle cx={tx + q[0] * scale} cy={ty + q[1] * scale} r="4" />{/each}
					{#if l.pts.length}
						<text x={tx + l.pts[l.pts.length - 1][0] * scale + 8} y={ty + l.pts[l.pts.length - 1][1] * scale - 8}>{l.label}</text>
					{/if}
				</g>
			{/each}
		</svg>
	{/if}
	{#if boxes.length || boxDraft || lassoPts.length}
		<svg class="cuts" aria-hidden="true">
			<defs>
				<pattern id="cut-hatch" width="12" height="12" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
					<rect width="6" height="12" fill="rgba(224, 87, 74, 0.18)" />
				</pattern>
			</defs>
			{#each boxes as bx, i (i)}<polygon class={bx.kind} points={bx.pts.map(sp).join(' ')} />{/each}
			{#if boxDraft}
				{@const [x, y, w, h] = boxDraft}
				<polygon class="draft" points={([[x, y], [x + w, y], [x + w, y + h], [x, y + h]] as XY[]).map(sp).join(' ')} />
			{/if}
			{#if lassoPts.length}
				<polyline class="lasso" points={lassoPts.map(sp).join(' ')} />
				<circle class="lasso-start" cx={tx + lassoPts[0][0] * scale} cy={ty + lassoPts[0][1] * scale} r="7" />
				{#each lassoPts.slice(1) as q, i (i)}<circle class="lasso-pt" cx={tx + q[0] * scale} cy={ty + q[1] * scale} r="3" />{/each}
			{/if}
		</svg>
	{/if}
	{#each pins as p (p.id)}
		{#if p.img}
			<button
				type="button"
				class="pin"
				class:half={!p.map}
				style:left="{tx + p.img[0] * scale}px"
				style:top="{ty + p.img[1] * scale}px"
				title="Pin {p.id}: drag to adjust"
				onpointerdown={(e) => down(e, p.id)}
			>
				{p.id}
			</button>
		{/if}
	{/each}
	<div class="tools">
		<button type="button" title="Zoom in" onpointerdown={(e) => e.stopPropagation()} onclick={() => zoomBy(1.5)}>+</button>
		<button type="button" title="Zoom out" onpointerdown={(e) => e.stopPropagation()} onclick={() => zoomBy(1 / 1.5)}>−</button>
		<button type="button" title="Fit the whole scan" onpointerdown={(e) => e.stopPropagation()} onclick={fitView}>⤢</button>
	</div>
	{#if tip}<div class="tip">{tip}</div>{:else if waiting != null}<div class="tip">Tap the spot for pin {waiting} on the scan</div>{/if}
</div>

<style>
	.view {
		position: absolute;
		inset: 0;
		overflow: hidden;
		background: #1c1814 repeating-conic-gradient(#221d18 0 25%, #1c1814 0 50%) 0 0 / 24px 24px;
		cursor: crosshair;
		touch-action: none;
		user-select: none;
	}
	img {
		position: absolute;
		left: 0;
		top: 0;
		transform-origin: 0 0;
		max-width: none;
		pointer-events: none;
		image-rendering: auto;
		box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.15);
	}
	.lines {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		pointer-events: none;
		overflow: visible;
	}
	.lines line {
		stroke: #f0a030;
		stroke-width: 3;
	}
	.lines circle {
		fill: #f0a030;
		stroke: #17130f;
		stroke-width: 2;
	}
	.lines .north line {
		stroke: #5fd0e8;
	}
	.lines .north circle {
		fill: #5fd0e8;
	}
	.lines .north text {
		fill: #5fd0e8;
	}
	.lines text {
		fill: #f0a030;
		font: 700 13px var(--sans);
		paint-order: stroke;
		stroke: #17130f;
		stroke-width: 3;
	}
	.cuts {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		pointer-events: none;
		overflow: visible;
	}
	.cuts polygon {
		stroke-width: 2;
		stroke-dasharray: 6 4;
		stroke-linejoin: round;
	}
	.cuts .draft {
		stroke: #5fd0e8;
		fill: rgba(95, 208, 232, 0.12);
	}
	.cuts .mask {
		stroke: #e0574a;
		fill: url(#cut-hatch);
	}
	.cuts .lasso {
		fill: rgba(95, 208, 232, 0.08);
		stroke: #5fd0e8;
		stroke-width: 2;
		stroke-linejoin: round;
	}
	.cuts .lasso-start {
		fill: #5fd0e8;
		stroke: #17130f;
		stroke-width: 2;
	}
	.cuts .lasso-pt {
		fill: #5fd0e8;
	}
	.pin {
		position: absolute;
		transform: translate(-50%, -50%);
		width: 22px;
		height: 22px;
		padding: 0;
		display: grid;
		place-items: center;
		border-radius: 50%;
		border: 2px solid #17130f;
		background: #e0574a;
		color: #fff;
		font: 700 0.7rem/1 var(--mono, monospace);
		cursor: grab;
		box-shadow: 0 0 0 2px rgba(255, 255, 255, 0.85);
	}
	.pin.half {
		animation: pulse 1.2s ease-in-out infinite;
	}
	@keyframes pulse {
		50% {
			box-shadow: 0 0 0 6px rgba(224, 87, 74, 0.35);
		}
	}
	.tools {
		position: absolute;
		top: 10px;
		right: 10px;
		display: flex;
		flex-direction: column;
		gap: 2px;
		z-index: 2;
	}
	.tools button {
		width: 30px;
		height: 30px;
		padding: 0;
		justify-content: center;
		font-weight: 700;
	}
	/* fingers need bigger targets */
	@media (pointer: coarse) {
		.pin {
			width: 32px;
			height: 32px;
			font-size: 0.8rem;
		}
		.tools button {
			width: 40px;
			height: 40px;
		}
	}
	.tip {
		position: absolute;
		left: 50%;
		bottom: 12px;
		transform: translateX(-50%);
		background: rgba(224, 87, 74, 0.95);
		color: #fff;
		padding: 4px 12px;
		border-radius: 999px;
		font-size: 0.8rem;
		font-weight: 600;
		white-space: nowrap;
		pointer-events: none;
	}
</style>
