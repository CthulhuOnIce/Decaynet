<script lang="ts">
	import { onDestroy } from 'svelte';

	let {
		year = $bindable(),
		min,
		max,
		density = [],
		onchange
	}: {
		year: number;
		min: number;
		max: number;
		/** counts per year from min..max: drawn as a histogram of "things happening" */
		density?: number[];
		onchange?: (year: number) => void;
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

	const ticks = $derived.by(() => {
		const out: number[] = [];
		const step = max - min > 120 ? 20 : 10;
		for (let y = Math.ceil(min / step) * step; y <= max; y += step) out.push(y);
		return out;
	});
	const pct = (y: number) => ((y - min) / Math.max(1, max - min)) * 100;
	const peak = $derived(Math.max(1, ...density));

	function onkey(e: KeyboardEvent) {
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

<div class="slider">
	<div class="controls">
		<button class="icon-btn" onclick={() => set(year - 10)} title="Back a decade (Shift+←)">«</button>
		<button class="icon-btn" onclick={() => set(year - 1)} title="Back a year (←)">‹</button>
		<button class="icon-btn play" onclick={toggle} title="Play / pause (Space)" aria-pressed={playing}>
			{playing ? '❚❚' : '▶'}
		</button>
		<button class="icon-btn" onclick={() => set(year + 1)} title="Forward a year (→)">›</button>
		<button class="icon-btn" onclick={() => set(year + 10)} title="Forward a decade (Shift+→)">»</button>
	</div>

	<div class="year" aria-live="polite">{year}</div>

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
		min-width: 4ch;
		line-height: 1;
		color: var(--ink);
		font-variant-numeric: tabular-nums;
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
</style>
