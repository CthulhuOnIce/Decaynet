<script lang="ts">
	import { onDestroy } from 'svelte';

	let {
		year = $bindable(),
		min,
		max,
		density = [],
		onchange,
		compact = false,
		keyboard = true
	}: {
		year: number;
		min: number;
		max: number;
		/** counts per year from min..max: drawn as a histogram of "things happening" */
		density?: number[];
		onchange?: (year: number) => void;
		/** one slim row (‹ year › and the track): for small screens where the map needs the room */
		compact?: boolean;
		/** the page's arrow keys and space step the year (off while the page uses them for something else) */
		keyboard?: boolean;
	} = $props();

	let playing = $state(false);
	let timer: ReturnType<typeof setInterval> | undefined;

	const set = (y: number) => {
		year = Math.max(min, Math.min(max, Math.round(y)));
		onchange?.(year);
	};

	function toggle() {
		playing = !playing;
		clearInterval(timer);
		if (playing) {
			if (year >= max) set(min);
			timer = setInterval(() => {
				if (year >= max) {
					playing = false;
					clearInterval(timer);
				} else set(year + 1);
			}, 260);
		}
	}

	onDestroy(() => clearInterval(timer));

	// The big year is a box you can type into: Enter (or leaving it) jumps there, Esc puts it back
	let draft = $state<string | null>(null);
	function commit() {
		if (draft == null) return;
		const n = Number(draft.trim());
		if (Number.isInteger(n) && /^\d{1,4}$/.test(draft.trim())) set(n);
		draft = null;
	}
	function yearKey(e: KeyboardEvent & { currentTarget: HTMLInputElement }) {
		if (e.key === 'Enter') {
			commit();
			e.currentTarget.blur();
		} else if (e.key === 'Escape') {
			draft = null;
			e.currentTarget.blur();
		} else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
			e.preventDefault();
			draft = null;
			set(year + (e.key === 'ArrowUp' ? 1 : -1) * (e.shiftKey ? 10 : 1));
		}
	}

	const ticks = $derived.by(() => {
		const out: number[] = [];
		const step = max - min > 120 ? 20 : 10;
		for (let y = Math.ceil(min / step) * step; y <= max; y += step) out.push(y);
		return out;
	});
	const pct = (y: number) => ((y - min) / Math.max(1, max - min)) * 100;
	const peak = $derived(Math.max(1, ...density));

	function onkey(e: KeyboardEvent) {
		if (!keyboard) return;
		const t = e.target as HTMLElement;
		if (t.closest('input:not([type=range]), textarea, select')) return;
		if (e.key === 'ArrowLeft' && (e.shiftKey || t.tagName !== 'INPUT')) set(year - (e.shiftKey ? 10 : 1));
		else if (e.key === 'ArrowRight' && (e.shiftKey || t.tagName !== 'INPUT')) set(year + (e.shiftKey ? 10 : 1));
		else if (e.key === ' ' && t.tagName !== 'BUTTON') {
			e.preventDefault();
			toggle();
		}
	}
</script>

<svelte:window onkeydown={onkey} />

<div class="slider" class:compact>
	<div class="controls">
		<button class="icon-btn wide" onclick={() => set(year - 10)} title="Back a decade (Shift+←)">«</button>
		<button class="icon-btn" onclick={() => set(year - 1)} title="Back a year (←)">‹</button>
		<button class="icon-btn play wide" onclick={toggle} title="Play / pause (Space)" aria-pressed={playing}>
			{playing ? '❚❚' : '▶'}
		</button>
		<button class="icon-btn" onclick={() => set(year + 1)} title="Forward a year (→)">›</button>
		<button class="icon-btn wide" onclick={() => set(year + 10)} title="Forward a decade (Shift+→)">»</button>
	</div>

	<input
		class="year"
		type="text"
		inputmode="numeric"
		maxlength="4"
		aria-label="Year: type one and press Enter"
		title="Type a year and press Enter (↑ ↓ step it)"
		value={draft ?? String(year)}
		onfocus={(e) => {
			if (playing) toggle();
			e.currentTarget.select();
		}}
		oninput={(e) => (draft = e.currentTarget.value.replace(/\D/g, ''))}
		onkeydown={yearKey}
		onblur={commit}
	/>

	<div class="track">
		{#if density.length}
			<div class="hist" aria-hidden="true">
				{#each density as d, i (i)}
					{#if d > 0}
						<span style:left="{pct(min + i)}%" style:height="{(d / peak) * 100}%"></span>
					{/if}
				{/each}
			</div>
		{/if}
		<input
			type="range"
			{min}
			{max}
			step="1"
			value={year}
			oninput={(e) => set(+e.currentTarget.value)}
			aria-label="Year"
		/>
		<div class="ticks" aria-hidden="true">
			{#each ticks as t (t)}
				<span style:left="{pct(t)}%">{t}</span>
			{/each}
		</div>
	</div>
</div>

<style>
	.slider {
		display: grid;
		grid-template-columns: auto auto 1fr;
		align-items: center;
		gap: 14px;
		padding: 10px 16px 18px;
		background: rgba(27, 23, 20, 0.94);
		border-top: 1px solid var(--line);
		backdrop-filter: blur(6px);
	}
	.controls {
		display: flex;
		gap: 4px;
	}
	.controls button {
		min-width: 32px;
		justify-content: center;
	}
	.play {
		background: var(--rust);
		border-color: var(--rust);
		color: white;
	}
	.year {
		font-family: var(--serif);
		font-size: 2.3rem;
		font-weight: 700;
		width: 4.2ch;
		min-width: 0;
		line-height: 1;
		color: var(--ink);
		font-variant-numeric: tabular-nums;
		/* an input that looks like the big year until you point at it */
		padding: 0 2px;
		margin: 0;
		background: transparent;
		border: 0;
		border-bottom: 2px solid transparent;
		border-radius: 0;
		box-shadow: none;
		cursor: text;
	}
	.year:hover {
		border-bottom-color: var(--line-2);
	}
	.year:focus {
		outline: none;
		border-bottom-color: var(--rust);
	}
	.track {
		position: relative;
		padding-top: 22px;
	}
	.hist {
		position: absolute;
		left: 8px;
		right: 8px;
		top: 0;
		height: 20px;
		pointer-events: none;
	}
	.hist span {
		position: absolute;
		bottom: 0;
		width: 2px;
		margin-left: -1px;
		background: var(--amber);
		opacity: 0.55;
		border-radius: 1px;
	}
	input[type='range'] {
		width: 100%;
		display: block;
	}
	.ticks {
		position: relative;
		height: 12px;
		margin: 0 8px;
	}
	.ticks span {
		position: absolute;
		transform: translateX(-50%);
		font-family: var(--mono);
		font-size: 0.68rem;
		color: var(--muted);
	}
	@media (max-width: 640px) {
		.slider {
			grid-template-columns: auto 1fr;
		}
		.controls {
			grid-column: 1 / -1;
			justify-content: center;
		}
		.year {
			font-size: 1.7rem;
		}
	}
	/* compact: one slim row */
	.slider.compact {
		grid-template-columns: auto auto 1fr;
		gap: 8px;
		padding: 6px 12px 8px;
	}
	.slider.compact .controls {
		grid-column: auto;
		gap: 2px;
	}
	.slider.compact .wide,
	.slider.compact .hist {
		display: none;
	}
	.slider.compact .year {
		font-size: 1.3rem;
		order: -1;
	}
	.slider.compact .track {
		padding-top: 0;
	}
	.slider.compact .controls button {
		min-width: 30px;
		padding: 4px 6px;
	}
</style>
