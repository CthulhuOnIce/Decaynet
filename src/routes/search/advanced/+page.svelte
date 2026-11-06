<script lang="ts">
	import { page } from '$app/state';
	import { can } from '$lib/perms';
	import KindBadge from '$lib/components/KindBadge.svelte';
	import { formatRange } from '$lib/time';
	import { CONFIDENCES, type Precision } from '$lib/types';
	import { MATCH_MODES, PER_PAGE, SEARCH_IN, SEARCH_PROPS, SORTS, TIME_WINDOW, readParams, type SearchResult } from '$lib/advancedSearch';

	let { data } = $props();
	// the form shows the search in the address bar: a reload of the page's data with the same search
	// (signing in again in the background, say) mustn't put the boxes back while someone types
	const search = $derived(page.url.search);
	const p = $derived(readParams(new URLSearchParams(search)));
	const vocab = $derived(page.data.vocab);

	// the time machine: a year and the few before it
	let tmYear = $state('');
	let fromBox = $state('');
	let toBox = $state('');
	$effect.pre(() => {
		fromBox = p.from;
		toBox = p.to;
		tmYear = p.to && p.from && Number(p.to) - Number(p.from) === TIME_WINDOW ? p.to : '';
	});
	function timeMachine() {
		if (!/^\d{4}$/.test(tmYear)) return;
		toBox = tmYear;
		fromBox = String(Number(tmYear) - TIME_WINDOW);
	}

	// on a phone, once there are results, the filters fold away above them (their summary says how many are set)
	let filtersOpen = $state(true);
	$effect(() => {
		void search;
		if (data.searched && matchMedia('(max-width: 800px)').matches) filtersOpen = false;
	});

	const used = (...xs: unknown[]) => xs.some((x) => (Array.isArray(x) ? x.length > 0 : !!x));
	const nFilters = $derived(
		[
			p.kinds.length,
			p.from || p.to,
			p.sfrom || p.sto || p.efrom || p.eto,
			p.statuses.length || p.statusNone,
			p.tags.length,
			p.articleStatuses.length || p.confidences.length,
			Object.keys(p.props).length,
			p.facts.some((f) => f.key),
			p.street || p.nfrom || p.nto
		].filter(Boolean).length
	);
	const pages = $derived(Math.ceil(data.total / PER_PAGE));
	// the same filters, opened as a grid (its own sorts aside, and the year searched as the year to work in)
	const recordsQuery = $derived.by(() => {
		const u = new URLSearchParams(page.url.search);
		u.delete('page');
		if (u.get('to')) u.set('y', u.get('to') as string);
		return u.toString();
	});
	function pageHref(n: number) {
		const u = new URL(page.url);
		u.searchParams.set('page', String(n));
		return `${u.pathname}?${u.searchParams}`;
	}
	/** the year a result is shown for on the map: the end of the years searched, or its last year */
	function mapYear(r: SearchResult) {
		if (p.to) return Number(p.to);
		if (r.exists_to) return Number(r.exists_to.slice(0, 4)) - 1;
		return new Date().getFullYear();
	}
	const range = (r: SearchResult) =>
		formatRange(r.exists_from, r.exists_from_precision as Precision, r.exists_to, r.exists_to_precision as Precision) || 'undated';
	const tagGroups = $derived(
		Object.entries(
			data.tags.reduce<Record<string, typeof data.tags>>((acc, t) => ((acc[t.facet_label] ??= []).push(t), acc), {})
		)
	);
</script>

<svelte:head><title>Advanced search · {page.data.settings.site_name}</title></svelte:head>

<div class="page adv">
	<div class="eyebrow"><a href="/search">Search</a> · Advanced</div>
	<h1>Advanced search</h1>

	<form method="get" class="layout">
		<details class="filters card" bind:open={filtersOpen}>
			<summary>
				<strong>Filters</strong>{#if nFilters}<span class="muted small"> · {nFilters} in use</span>{/if}
			</summary>

			<fieldset>
				<legend>Text</legend>
				<input name="q" value={p.q} placeholder="A name, an address, words in an article…" aria-label="Text to search for" />
				<select name="match" aria-label="How to match">
					{#each MATCH_MODES as m (m.id)}<option value={m.id} selected={p.match === m.id}>{m.label}</option>{/each}
				</select>
				<div class="checks">
					{#each SEARCH_IN as s (s.id)}
						<label class="check"><input type="checkbox" name="in" value={s.id} checked={p.in.includes(s.id)} /> {s.label}</label>
					{/each}
				</div>
			</fieldset>

			<fieldset>
				<legend>Kind</legend>
				<div class="checks two">
					{#each vocab.kinds as k (k.id)}
						<label class="check"><input type="checkbox" name="kind" value={k.id} checked={p.kinds.includes(k.id)} /> {k.plural}</label>
					{/each}
				</div>
			</fieldset>

			<fieldset>
				<legend>When</legend>
				<div class="tm">
					<label for="tm">Time machine: in</label>
					<input id="tm" class="year" bind:value={tmYear} placeholder="1950" inputmode="numeric" onchange={timeMachine} />
					<button type="button" class="ghost small-btn" onclick={timeMachine}>and the {TIME_WINDOW} years before</button>
				</div>
				<div class="pair">
					<label>Existed between <input name="from" class="year" bind:value={fromBox} placeholder="1900" /></label>
					<label>and <input name="to" class="year" bind:value={toBox} placeholder="1960" /></label>
				</div>
				<p class="hint">Names, addresses and conditions are read as they were then; a later name doesn't match.</p>
				<div class="pair">
					<label>Started between <input name="sfrom" class="year" value={p.sfrom} /></label>
					<label>and <input name="sto" class="year" value={p.sto} /></label>
				</div>
				<div class="pair">
					<label>Ended between <input name="efrom" class="year" value={p.efrom} /></label>
					<label>and <input name="eto" class="year" value={p.eto} /></label>
				</div>
			</fieldset>

			<details class="sub" open={used(p.statuses, p.statusNone, p.statusYear)}>
				<summary>Condition</summary>
				<label class="inline">In <input name="status_year" class="year" value={p.statusYear} placeholder={p.to || 'today'} /></label>
				<div class="checks two">
					{#each vocab.statuses as s (s.id)}
						<label class="check"><input type="checkbox" name="status" value={s.id} checked={p.statuses.includes(s.id)} /><span class="dot" style:background={s.color}></span>{s.label}</label>
					{/each}
					<label class="check"><input type="checkbox" name="status_none" value="1" checked={p.statusNone} /> None recorded</label>
				</div>
			</details>

			<details class="sub" open={used(p.tags)}>
				<summary>Tag</summary>
				<select name="tag" aria-label="Tag">
					<option value="">Any</option>
					{#each tagGroups as [facet, list] (facet)}
						<optgroup label={facet}>
							{#each list as t (t.id)}<option value={t.id} selected={p.tags.includes(t.id)}>{t.path}</option>{/each}
						</optgroup>
					{/each}
				</select>
				<p class="hint">Includes its sub-traits.</p>
			</details>

			<details class="sub" open={used(Object.keys(p.props))}>
				<summary>Has or lacks</summary>
				<div class="props">
					{#each SEARCH_PROPS as pr (pr.id)}
						<label for="has-{pr.id}">{pr.label}</label>
						<select id="has-{pr.id}" name="has_{pr.id}">
							<option value="">Any</option>
							<option value="set" selected={p.props[pr.id] === 'set'}>Has</option>
							<option value="unset" selected={p.props[pr.id] === 'unset'}>Missing</option>
						</select>
					{/each}
				</div>
			</details>

			<details class="sub" open={p.facts.some((f) => f.key)}>
				<summary>Facts</summary>
				{#each p.facts as f, i (i)}
					{@const n = i + 1}
					<div class="fact">
						<select name="fact{n}" aria-label="Fact {n}">
							<option value="">—</option>
							{#each vocab.attributeKeys as a (a.id)}<option value={a.id} selected={f.key === a.id}>{a.label}</option>{/each}
						</select>
						<input name="fact{n}_min" value={f.min} placeholder="min" aria-label="Fact {n} at least" class="num" />
						<input name="fact{n}_max" value={f.max} placeholder="max" aria-label="Fact {n} at most" class="num" />
						<input name="fact{n}_text" value={f.text} placeholder="text" aria-label="Fact {n} text" />
						<label class="check small"><input type="checkbox" name="fact{n}_unset" value="1" checked={f.unset} /> not recorded</label>
					</div>
				{/each}
			</details>

			<details class="sub" open={used(p.street, p.nfrom, p.nto)}>
				<summary>Address</summary>
				<input name="street" value={p.street} placeholder="Street (any of its names, close spellings)" aria-label="Street" />
				<div class="pair">
					<label>Numbers from <input name="nfrom" class="year" value={p.nfrom} /></label>
					<label>to <input name="nto" class="year" value={p.nto} /></label>
				</div>
			</details>

			<details class="sub" open={used(p.articleStatuses, p.confidences)}>
				<summary>Article and certainty</summary>
				<div class="checks two">
					{#each vocab.articleStatuses as s (s.id)}
						<label class="check"><input type="checkbox" name="astatus" value={s.id} checked={p.articleStatuses.includes(s.id)} /> {s.label}</label>
					{/each}
				</div>
				<div class="checks two">
					{#each CONFIDENCES as c (c)}
						<label class="check"><input type="checkbox" name="conf" value={c} checked={p.confidences.includes(c)} /> dates {c}</label>
					{/each}
				</div>
			</details>

			<div class="row actions">
				<label class="inline">Sort
					<select name="sort">{#each SORTS as s (s.id)}<option value={s.id} selected={p.sort === s.id}>{s.label}</option>{/each}</select>
				</label>
				<button class="primary">Search</button>
				<a class="btn ghost" href="/search/advanced">Clear</a>
			</div>
		</details>

		<section class="results">
			{#if data.error}<p class="notice error">{data.error}</p>{/if}
			{#if !data.searched}
				<p class="muted">
					Set any filters and search. Leave the text empty to list everything that fits: every building with no condition recorded,
					everything standing on Broadway in 1950, every business with more than 100 employees.
				</p>
			{:else}
				<p class="count">
					<strong>{data.total.toLocaleString()}</strong> found{p.from || p.to ? ` (${p.from || '…'}–${p.to || '…'})` : ''}{pages > 1
						? ` · page ${p.page} of ${pages}`
						: ''}
					{#if can('manage_records')}
						· <a href="/admin/records?{recordsQuery}" title="Edit every result together, as of a year and citing a source">Open in Records</a>
					{/if}
				</p>
				<ul class="plain-list">
					{#each data.results as r (r.id)}
						<li>
							<div class="top">
								<a class="name" href="/e/{r.slug}">{r.name}</a>
								<KindBadge kind={r.kind} />
								{#if r.status_label}<span class="status"><span class="dot" style:background={r.status_color}></span>{r.status_label}</span>{/if}
							</div>
							<div class="muted small meta">
								{#if r.name_then && r.name_then !== r.name}<span>then: <strong>{r.name_then}</strong></span>{/if}
								<span class="date">{range(r)}</span>
								{#if r.address}<span>{r.address}</span>{/if}
								{#if r.matched && r.matched !== r.name}<span class="matched">matched {r.matched_in}: “{r.matched}”</span>{/if}
								{#if r.lon != null}<a href="/?y={mapYear(r)}&sel={r.id}">on the map in {mapYear(r)} →</a>{/if}
							</div>
						</li>
					{:else}
						<li class="muted">Nothing fits all of that. Try fewer filters, or fuzzy matching.</li>
					{/each}
				</ul>
				{#if pages > 1}
					<nav class="pager">
						{#if p.page > 1}<a class="btn ghost" href={pageHref(p.page - 1)}>← Previous</a>{/if}
						{#if p.page < pages}<a class="btn ghost" href={pageHref(p.page + 1)}>Next →</a>{/if}
					</nav>
				{/if}
			{/if}
		</section>
	</form>
</div>

<style>
	.layout {
		display: grid;
		grid-template-columns: minmax(280px, 340px) 1fr;
		gap: 16px;
		align-items: start;
	}
	.filters {
		display: grid;
		gap: 10px;
		position: sticky;
		top: calc(var(--header-h) + 8px);
		max-height: calc(100dvh - var(--header-h) - 24px);
		overflow-y: auto;
	}
	.filters > summary {
		cursor: pointer;
	}
	fieldset {
		display: grid;
		gap: 6px;
		margin: 0;
		padding: 0;
		border: 0;
	}
	legend,
	.sub > summary {
		padding: 0;
		margin-bottom: 4px;
		font-size: 0.78rem;
		font-weight: 600;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--ink-2);
	}
	.sub > summary {
		cursor: pointer;
	}
	.sub {
		display: grid;
		gap: 6px;
		padding-top: 6px;
		border-top: 1px solid var(--line);
	}
	.checks {
		display: grid;
		gap: 2px 10px;
	}
	.checks.two {
		grid-template-columns: 1fr 1fr;
	}
	.check {
		display: flex;
		gap: 6px;
		align-items: center;
		margin: 0;
		font-weight: normal;
		font-size: 0.85rem;
		color: var(--ink-2);
	}
	.pair,
	.tm {
		display: flex;
		gap: 8px;
		align-items: center;
		flex-wrap: wrap;
	}
	.pair label,
	.inline {
		display: flex;
		gap: 6px;
		align-items: center;
		margin: 0;
		font-size: 0.85rem;
		font-weight: normal;
		color: var(--ink-2);
	}
	.tm label {
		margin: 0;
		font-size: 0.85rem;
	}
	input.year {
		width: 5.5em;
	}
	input.num {
		width: 4.5em;
	}
	.props {
		display: grid;
		grid-template-columns: 1fr auto;
		gap: 4px 8px;
		align-items: center;
		font-size: 0.85rem;
	}
	.props label {
		margin: 0;
		font-weight: normal;
	}
	.fact {
		display: flex;
		gap: 4px;
		flex-wrap: wrap;
		align-items: center;
	}
	.fact select {
		flex: 1 1 100%;
	}
	.fact input:not(.num) {
		flex: 1;
		min-width: 5em;
	}
	.dot {
		display: inline-block;
		width: 9px;
		height: 9px;
		border-radius: 50%;
		flex: none;
	}
	.actions {
		display: flex;
		gap: 8px;
		align-items: center;
		flex-wrap: wrap;
		padding-top: 8px;
		border-top: 1px solid var(--line);
	}
	.results .count {
		margin: 0 0 8px;
	}
	.results li {
		padding: 8px 0;
		border-bottom: 1px solid var(--line);
	}
	.top {
		display: flex;
		gap: 8px;
		align-items: center;
		flex-wrap: wrap;
	}
	.name {
		font-weight: 600;
	}
	.status {
		display: inline-flex;
		gap: 5px;
		align-items: center;
		font-size: 0.8rem;
		color: var(--ink-2);
	}
	.meta {
		display: flex;
		gap: 4px 12px;
		flex-wrap: wrap;
		margin-top: 2px;
	}
	.matched {
		font-style: italic;
	}
	.pager {
		display: flex;
		gap: 8px;
		margin-top: 12px;
	}
	@media (max-width: 800px) {
		.layout {
			grid-template-columns: 1fr;
		}
		.filters {
			position: static;
			max-height: none;
		}
	}
</style>
