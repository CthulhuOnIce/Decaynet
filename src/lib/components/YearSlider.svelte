<script lang="ts">
	import { onDestroy } from 'svelte';
	import { HOLD_PRESETS, LINGER_FACTOR, PLAYBACK_DEFAULTS, STEPS, holdLabel, loadPlayback, savePlayback, type Playback } from '$lib/playback';

	let {
		year = $bindable(),
		min,
		max,
		density = [],
		onchange,
		compact = false,
		keyboard = true,
		busy = undefined
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
		/** the map is still drawing the year (playback can wait for it); leave unset where there's no map to wait for */
		busy?: boolean;
	} = $props();

	let playing = $state(false);
	let timer: ReturnType<typeof setTimeout> | undefined;

	const set = (y: number) => {
		year = Math.max(min, Math.min(max, Math.round(y)));
		onchange?.(year);
	};

	// ---------------------------------------------------------------- playback
	// Right-click (or hold) ▶ for the options; they're kept in this browser.
	let opts = $state<Playback>(loadPlayback());
	$effect(() => savePlayback($state.snapshot(opts)));
	const lo = $derived(Math.max(min, Math.min(opts.from ?? min, opts.to ?? max)));
	const hi = $derived(Math.min(max, Math.max(opts.to ?? max, opts.from ?? min)));
	const back = $derived(opts.direction === 'back');
	/** nothing recorded that year (the slider's histogram) */
	const quiet = (y: number) => density.length > 0 && (density[y - min] ?? 0) === 0;
	const holdFor = (y: number) => opts.hold * (opts.linger && density.length > 0 && !quiet(y) ? LINGER_FACTOR : 1);
	function nextYear(y: number): number | null {
		const d = (back ? -1 : 1) * opts.step;
		let n = y + d;
		if (opts.skipQuiet) for (let guard = 0; n >= lo && n <= hi && quiet(n) && guard < 10000; guard++) n += d;
		if (n > hi || n < lo) return opts.loop ? (back ? hi : lo) : null;
		return n;
	}
	/** hold the year on screen: once the map has drawn it, when asked to wait for that */
	function hold(ms: number) {
		clearTimeout(timer);
		const t0 = Date.now();
		const tick = () => {
			if (!playing) return;
			// a slow year shouldn't stall the show for ever
			if (opts.waitForMap && busy && Date.now() - t0 < 15000) return void (timer = setTimeout(tick, 60));
			timer = setTimeout(advance, ms);
		};
		// the map gets a moment to start loading the new year
		timer = setTimeout(tick, opts.waitForMap && busy !== undefined ? 150 : 0);
	}
	function advance() {
		if (!playing) return;
		const n = nextYear(year);
		if (n == null) return stop();
		set(n);
		hold(holdFor(n));
	}
	function start() {
		playing = true;
		menuOpen = false;
		// from the start of the range when outside it or already at its end
		if (year < lo || year > hi || (back ? year <= lo : year >= hi)) set(back ? hi : lo);
		hold(holdFor(year));
	}
	function stop() {
		playing = false;
		clearTimeout(timer);
	}
	function toggle() {
		if (playing) stop();
		else start();
	}

	// the options: right-click, or hold on a touch screen
	let menuOpen = $state(false);
	let menuEl = $state<HTMLDivElement>();
	let pressTimer: ReturnType<typeof setTimeout> | undefined;
	let held = false;
	function pressStart(e: PointerEvent) {
		if (e.pointerType === 'mouse') return;
		held = false;
		pressTimer = setTimeout(() => {
			held = true;
			menuOpen = true;
		}, 500);
	}
	const pressEnd = () => clearTimeout(pressTimer);
	function playClick() {
		// a hold that opened the options isn't also a press of ▶
		if (held) return void (held = false);
		toggle();
	}
	function outside(e: PointerEvent) {
		if (menuOpen && menuEl && !menuEl.contains(e.target as Node) && !(e.target as HTMLElement).closest('.play')) menuOpen = false;
	}
	const yearOrNull = (v: string) => (/^\d{1,4}$/.test(v.trim()) ? Number(v.trim()) : null);

	onDestroy(() => {
		clearTimeout(timer);
		clearTimeout(pressTimer);
	});

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
		} else if (e.key === 'Escape' && menuOpen) menuOpen = false;
	}
</script>

<svelte:window onkeydown={onkey} onpointerdown={outside} />

<div class="slider" class:compact>
	<div class="controls">
		<button class="icon-btn wide" onclick={() => set(year - 10)} title="Back a decade (Shift+←)">«</button>
		<button class="icon-btn" onclick={() => set(year - 1)} title="Back a year (←)">‹</button>
		<button
			class="icon-btn play wide"
			onclick={playClick}
			oncontextmenu={(e) => {
				e.preventDefault();
				menuOpen = !menuOpen;
			}}
			onpointerdown={pressStart}
			onpointerup={pressEnd}
			onpointerleave={pressEnd}
			onpointercancel={pressEnd}
			title="Play / pause (Space) · right-click or hold for options"
			aria-pressed={playing}
			aria-haspopup="dialog"
			aria-expanded={menuOpen}
		>
			{playing ? '❚❚' : '▶'}
		</button>
		<button class="icon-btn" onclick={() => set(year + 1)} title="Forward a year (→)">›</button>
		<button class="icon-btn wide" onclick={() => set(year + 10)} title="Forward a decade (Shift+→)">»</button>
	</div>

	{#if menuOpen}
		<div class="playmenu" role="dialog" aria-label="Playback options" bind:this={menuEl}>
			<div class="pm-head">
				<strong>Playback</strong>
				<button class="ghost x" onclick={() => (menuOpen = false)} aria-label="Close">✕</button>
			</div>
			<div class="pm-row">
				<label for="pm-hold">Each year <span class="muted">{holdLabel(opts.hold)}</span></label>
				<input id="pm-hold" type="range" min="100" max="3000" step="50" bind:value={opts.hold} />
				<div class="pm-seg">
					{#each HOLD_PRESETS as h (h.ms)}
						<button class:on={opts.hold === h.ms} onclick={() => (opts.hold = h.ms)}>{h.label}</button>
					{/each}
				</div>
			</div>
			<div class="pm-row pm-two">
				<div>
					<span class="pm-label">Step</span>
					<div class="pm-seg">
						{#each STEPS as n (n)}<button class:on={opts.step === n} onclick={() => (opts.step = n)} title="{n} year{n === 1 ? '' : 's'} at a time">{n}</button>{/each}
					</div>
				</div>
				<div>
					<span class="pm-label">Direction</span>
					<div class="pm-seg">
						<button class:on={!back} onclick={() => (opts.direction = 'forward')}>Forward</button>
						<button class:on={back} onclick={() => (opts.direction = 'back')}>Back</button>
					</div>
				</div>
			</div>
			<div class="pm-row">
				<span class="pm-label">Years</span>
				<div class="pm-years">
					<input aria-label="Play from" inputmode="numeric" placeholder={String(min)} value={opts.from ?? ''} onchange={(e) => (opts.from = yearOrNull(e.currentTarget.value))} />
					<span>to</span>
					<input aria-label="Play to" inputmode="numeric" placeholder={String(max)} value={opts.to ?? ''} onchange={(e) => (opts.to = yearOrNull(e.currentTarget.value))} />
					<button class="ghost small-btn" onclick={() => (opts.from = year)} title="Start the range at {year}">From {year}</button>
				</div>
			</div>
			<div class="pm-row pm-checks">
				<label><input type="checkbox" bind:checked={opts.loop} /> Loop</label>
				{#if density.length}
					<label title="Years with things happening (the amber ticks) stay {LINGER_FACTOR}× as long"><input type="checkbox" bind:checked={opts.linger} /> Linger on eventful years</label>
					<label title="Jump over years with nothing recorded"><input type="checkbox" bind:checked={opts.skipQuiet} /> Skip quiet years</label>
				{/if}
				{#if busy !== undefined}
					<label title="Each year is held once the map has drawn it, however long that takes"><input type="checkbox" bind:checked={opts.waitForMap} /> Wait for the map to draw each year</label>
				{/if}
			</div>
			<div class="pm-foot">
				<button class="primary" onclick={toggle}>{playing ? '❚❚ Pause' : '▶ Play'}</button>
				<button class="ghost small-btn" onclick={() => (opts = { ...PLAYBACK_DEFAULTS })}>Reset</button>
			</div>
		</div>
	{/if}

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
		position: relative;
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
	.playmenu {
		position: absolute;
		left: 12px;
		bottom: calc(100% + 8px);
		z-index: 20;
		display: grid;
		gap: 10px;
		width: min(340px, calc(100vw - 24px));
		padding: 12px 14px;
		background: var(--panel);
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45);
		font-size: 0.85rem;
	}
	.pm-head,
	.pm-foot {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
	}
	.pm-row {
		display: grid;
		gap: 4px;
	}
	.pm-row label,
	.pm-label {
		margin: 0;
		font-size: 0.78rem;
		color: var(--ink-2);
	}
	.pm-row input[type='range'] {
		width: 100%;
	}
	.pm-two {
		grid-template-columns: auto 1fr;
		gap: 12px;
	}
	.pm-seg {
		display: flex;
		gap: 2px;
	}
	.pm-seg button {
		flex: 1;
		justify-content: center;
		padding: 3px 6px;
		font-size: 0.78rem;
	}
	.pm-seg button.on {
		background: var(--rust);
		border-color: var(--rust);
		color: white;
	}
	.pm-years {
		display: flex;
		gap: 6px;
		align-items: center;
	}
	.pm-years input {
		width: 4.6em;
	}
	.pm-checks {
		gap: 4px;
	}
	.pm-checks label {
		display: flex;
		gap: 6px;
		align-items: center;
		font-size: 0.82rem;
		color: var(--ink);
	}
	button.x {
		padding: 0 6px;
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
