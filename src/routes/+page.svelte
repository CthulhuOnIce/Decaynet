<script lang="ts">
	import { replaceState } from '$app/navigation';
	import { page } from '$app/state';
	import { untrack } from 'svelte';
	import TimeMachineMap from '$lib/components/TimeMachineMap.svelte';
	import YearSlider from '$lib/components/YearSlider.svelte';
	import TagSelect from '$lib/components/TagSelect.svelte';
	import EntityPanel from '$lib/components/EntityPanel.svelte';
	import { formatFuzzy, yearToDate } from '$lib/time';
	import type { EntitySnapshot, Picked } from '$lib/types';

	let { data } = $props();

	// ---- state, seeded from a shareable URL: /?y=1955&sel=<uuid>&c=-87.33,41.60,15
	const params = page.url.searchParams;
	let year = $state(
		untrack(() => Math.max(data.minYear, Math.min(data.maxYear, Number(params.get('y')) || data.settings.default_year)))
	);
	let basemap = $state(untrack(() => data.settings.basemap_mode));
	let selected = $state<string | null>(params.get('sel'));
	const c = params.get('c')?.split(',').map(Number);
	const startView =
		c?.length === 3 && c.every(Number.isFinite)
			? { center: [c[0], c[1]] as [number, number], zoom: c[2] }
			: undefined;
	let view = $state(startView);

	const NON_SPATIAL = ['person', 'organization', 'event', 'media'];
	const spatialKinds = $derived(data.vocab.kinds.filter((k) => !NON_SPATIAL.includes(k.id)));
	// Initial visibility only; the user toggles from here
	let kindsOn = $state<Record<string, boolean>>(
		untrack(() => Object.fromEntries(data.vocab.kinds.filter((k) => !NON_SPATIAL.includes(k.id)).map((k) => [k.id, true])))
	);
	const kinds = $derived(Object.keys(kindsOn).filter((k) => kindsOn[k]));
	let ghosts = $state(true);
	let tag = $state<string>(params.get('tag') ?? '');
	let showMoments = $state(true);
	let panelOpen = $state(true);

	// ---- selected entity, folded to the current year
	let snap = $state<EntitySnapshot | null>(null);
	let snapLoading = $state(false);
	let mapRef: ReturnType<typeof TimeMachineMap> | undefined = $state();

	$effect(() => {
		const id = selected;
		const at = yearToDate(year);
		if (!id) {
			snap = null;
			return;
		}
		const ctrl = new AbortController();
		snapLoading = true;
		const t = setTimeout(async () => {
			try {
				const res = await fetch(`/api/entity/${id}?at=${at}`, { signal: ctrl.signal });
				if (res.ok) snap = await res.json();
			} catch {
				/* aborted */
			} finally {
				if (!ctrl.signal.aborted) snapLoading = false;
			}
		}, 120);
		return () => {
			clearTimeout(t);
			ctrl.abort();
		};
	});

	function pickById(id: string, fly = true) {
		selected = id;
		if (!fly) return;
		fetch(`/api/entity/${id}?at=${yearToDate(year)}`)
			.then((r) => (r.ok ? r.json() : null))
			.then((s: EntitySnapshot | null) => {
				if (s?.location) mapRef?.flyTo(s.location.coordinates[0], s.location.coordinates[1], 15.5);
			});
	}

	// ---- moments (events / photos near this year)
	type Moment = { id: string; slug: string; kind: string; name: string; subtype: string; color?: string; from: string; from_precision: string; years_away?: number };
	let moments = $state<Moment[]>([]);
	function onmoments(fc: { features: GeoJSON.Feature[]; unplaced: unknown[] }) {
		const placed = fc.features.map((f) => f.properties as Moment);
		moments = [...placed, ...(fc.unplaced as Moment[])].sort((a, b) => a.from.localeCompare(b.from));
	}

	// ---- keep the URL shareable
	let urlTimer: ReturnType<typeof setTimeout> | undefined;
	$effect(() => {
		const y = year;
		const s = selected;
		const v = view;
		const tg = tag;
		untrack(() => {
			clearTimeout(urlTimer);
			urlTimer = setTimeout(() => {
				const u = new URL(page.url);
				u.searchParams.set('y', String(y));
				if (s) u.searchParams.set('sel', s);
				else u.searchParams.delete('sel');
				if (v) u.searchParams.set('c', `${v.center[0]},${v.center[1]},${v.zoom}`);
				if (tg) u.searchParams.set('tag', tg);
				else u.searchParams.delete('tag');
				replaceState(u, {});
			}, 300);
		});
	});
</script>

<svelte:head><title>{year} · {data.settings.site_name}</title></svelte:head>

<div class="shell" class:with-panel={!!selected}>
	<div class="map-area">
		<TimeMachineMap
			bind:this={mapRef}
			{year}
			minYear={data.minYear}
			maxYear={data.maxYear}
			{kinds}
			{ghosts}
			tag={tag || null}
			moments={showMoments}
			{selected}
			{basemap}
			center={startView?.center ?? [data.settings.map_center_lon, data.settings.map_center_lat]}
			zoom={startView?.zoom ?? data.settings.map_zoom}
			onselect={(p: Picked | null) => (selected = p?.id ?? null)}
			{onmoments}
			onview={(v) => (view = v)}
		/>

		<section class="controls" class:collapsed={!panelOpen} aria-label="Map layers">
			<button class="toggle ghost" onclick={() => (panelOpen = !panelOpen)} aria-expanded={panelOpen}>
				{panelOpen ? '‹ Layers' : 'Layers ›'}
			</button>
			{#if panelOpen}
				<div class="group">
					<div class="eyebrow">Show</div>
					{#each spatialKinds as k (k.id)}
						<label class="check">
							<input type="checkbox" bind:checked={kindsOn[k.id]} />
							<span class="sw" style:background={k.color}></span>{k.plural}
						</label>
					{/each}
					<label class="check" title="Draw demolished buildings and vacated streets as dashed outlines">
						<input type="checkbox" bind:checked={ghosts} />
						<span class="sw ghost-sw"></span>Ghosts of lost places
					</label>
					<label class="check">
						<input type="checkbox" bind:checked={showMoments} />
						<span class="sw" style:background="var(--amber)"></span>Events ±5 yrs
					</label>
				</div>

				<div class="group">
					<div class="eyebrow">Modern basemap</div>
					<div class="seg" role="radiogroup" aria-label="Modern basemap">
						{#each [['fade', 'Fade with time'], ['always', 'Always'], ['hidden', 'Hidden']] as [v, l] (v)}
							<button class:on={basemap === v} onclick={() => (basemap = v as typeof basemap)} role="radio" aria-checked={basemap === v}>{l}</button>
						{/each}
					</div>
					<p class="hint">Hide it when the historical layout differs from today's streets.</p>
					{#if data.user}<p class="hint"><a href="/workbench">Trace from a scanned map in the workbench →</a></p>{/if}
				</div>

				<div class="group">
					<div class="eyebrow">Only things tagged</div>
					<div onchange={(e) => (tag = (e.target as HTMLSelectElement).value)}>
						<TagSelect tags={data.tags} by="slug" value={tag} placeholder="(anything)" name="tag" />
					</div>
					{#if tag}<p class="hint">Includes sub-traits, as of {year}. <a href="/tags/{tag}">Tag page →</a></p>{/if}
				</div>

				<div class="group legend">
					<div class="eyebrow">Condition in {year}</div>
					{#each data.vocab.statuses.filter((s) => ['active', 'restored', 'declining', 'vacant', 'abandoned', 'ruin', 'demolished'].includes(s.id)) as s (s.id)}
						<div class="leg"><span class="sw round" style:background={s.color}></span>{s.label}</div>
					{/each}
				</div>

				{#if showMoments}
					<div class="group moments">
						<div class="eyebrow">Around {year}</div>
						{#if moments.length}
							<ul class="plain-list">
								{#each moments as m (m.id)}
									<li>
										<span class="date">{formatFuzzy(m.from, m.from_precision as never)}</span>
										<button class="link" onclick={() => pickById(m.id)}>{m.name}</button>
									</li>
								{/each}
							</ul>
						{:else}
							<p class="muted small">Nothing recorded within five years. <a href="/new?kind=event">Add an event?</a></p>
						{/if}
					</div>
				{/if}
			{/if}
		</section>

		<div class="slider-dock">
			<YearSlider bind:year min={data.minYear} max={data.maxYear} density={data.density} />
		</div>
	</div>

	{#if selected}
		<div class="side">
			<EntityPanel {snap} {year} loading={snapLoading} onclose={() => (selected = null)} onpick={(id) => pickById(id)} />
		</div>
	{/if}
</div>

<style>
	.shell {
		display: grid;
		grid-template-columns: 1fr;
		height: 100%;
	}
	.shell.with-panel {
		grid-template-columns: 1fr minmax(300px, 380px);
	}
	.map-area {
		position: relative;
		min-width: 0;
	}
	.side {
		min-height: 0;
		overflow: hidden;
	}
	.slider-dock {
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		z-index: 5;
	}
	.controls {
		position: absolute;
		top: 12px;
		left: 12px;
		bottom: 112px;
		width: 250px;
		z-index: 4;
		overflow-y: auto;
		background: rgba(27, 23, 20, 0.94);
		border: 1px solid var(--line);
		border-radius: var(--radius);
		padding: 8px 12px 12px;
		font-size: 0.86rem;
		backdrop-filter: blur(6px);
	}
	.controls.collapsed {
		bottom: auto;
		width: auto;
		padding: 4px;
	}
	.toggle {
		border: 0;
		padding: 2px 4px;
		font-size: 0.8rem;
		color: var(--muted);
	}
	.group {
		margin-top: 12px;
	}
	.group .eyebrow {
		margin-bottom: 6px;
	}
	.check {
		display: flex;
		align-items: center;
		gap: 7px;
		margin: 3px 0;
		font-size: 0.86rem;
		color: var(--ink);
		cursor: pointer;
	}
	.sw {
		width: 12px;
		height: 12px;
		border-radius: 3px;
		flex: none;
	}
	.sw.round {
		border-radius: 50%;
	}
	.ghost-sw {
		border: 1.5px dashed #8c8173;
	}
	.seg {
		display: flex;
		gap: 2px;
	}
	.seg button {
		flex: 1;
		padding: 4px 6px;
		font-size: 0.75rem;
		justify-content: center;
	}
	.seg button.on {
		background: var(--rust);
		border-color: var(--rust);
		color: #fff;
	}
	.legend .leg {
		display: flex;
		align-items: center;
		gap: 7px;
		font-size: 0.8rem;
		color: var(--ink-2);
		margin: 2px 0;
	}
	.group :global(select) {
		font-size: 0.82rem;
		padding: 5px 6px;
	}
	.moments li {
		font-size: 0.82rem;
		padding: 5px 0;
	}
	.moments .date {
		display: block;
		font-size: 0.7rem;
		color: var(--muted);
	}
	button.link {
		background: none;
		border: 0;
		padding: 0;
		color: var(--ink);
		font: inherit;
		text-align: left;
		cursor: pointer;
	}
	button.link:hover {
		color: var(--rust-2);
	}
	@media (max-width: 760px) {
		.shell.with-panel {
			grid-template-columns: 1fr;
			grid-template-rows: 1fr 45%;
		}
		.controls {
			width: 210px;
		}
	}
</style>
