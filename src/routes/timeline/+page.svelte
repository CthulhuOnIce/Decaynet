<script lang="ts">
	import { formatFuzzy } from '$lib/time';

	let { data } = $props();
	const CATS = [
		{ id: 'event', label: 'Events' },
		{ id: 'start', label: 'Built / founded / born' },
		{ id: 'end', label: 'Demolished / closed / died' },
		{ id: 'status', label: 'Decline (vacant → ruin)' }
	];
</script>

<svelte:head><title>Timeline · {data.settings.site_name}</title></svelte:head>

<div class="page">
	<h1>Chronology</h1>
	<p class="muted">Everything dated in the wiki, folded into one city-wide timeline.</p>

	<form method="get" class="card filters">
		<div class="fields">
			<div><label for="from">From</label><input id="from" name="from" type="number" value={data.from} /></div>
			<div><label for="to">To</label><input id="to" name="to" type="number" value={data.to} /></div>
			<div>
				<label for="kind">Kind</label>
				<select id="kind" name="kind">
					<option value="">all</option>
					{#each data.vocab.kinds as k (k.id)}<option value={k.id} selected={data.kind === k.id}>{k.plural}</option>{/each}
				</select>
			</div>
		</div>
		<div class="row cats">
			{#each CATS as c (c.id)}
				<label class="row"><input type="checkbox" name="cats" value={c.id} checked={data.cats.includes(c.id)} />{c.label}</label>
			{/each}
			<button class="primary">Apply</button>
		</div>
	</form>

	{#if data.error}<p class="notice error">{data.error}</p>{/if}

	{#each data.decades as d (d.decade)}
		<section class="decade">
			<h2><a href="/?y={d.decade + 5}">{d.decade}s</a></h2>
			<ol class="items">
				{#each d.items as r, i (r.entity_id + r.category + i)}
					<li>
						<span class="dot" style:background={r.color}></span>
						<span class="date">{formatFuzzy(r.at, r.at_precision)}</span>
						<span class="label" style:color={r.color}>{r.label}</span>
						<a href="/e/{r.slug}?y={r.at.slice(0, 4)}">{r.name}</a>
						<a class="map muted small" href="/?y={r.at.slice(0, 4)}&sel={r.entity_id}" title="See it on the map">map ↗</a>
					</li>
				{/each}
			</ol>
		</section>
	{:else}
		<p class="muted">Nothing dated in this range yet.</p>
	{/each}
</div>

<style>
	.filters {
		margin: 16px 0 24px;
	}
	.cats {
		margin-top: 10px;
		gap: 16px;
	}
	.cats label {
		margin: 0;
		gap: 6px;
		font-size: 0.86rem;
	}
	.decade h2 {
		position: sticky;
		top: var(--header-h);
		background: var(--bg);
		padding: 8px 0;
		margin: 24px 0 4px;
		font-size: 1.8rem;
		z-index: 2;
	}
	.decade h2 a {
		color: var(--ink);
	}
	.items {
		list-style: none;
		margin: 0;
		padding: 0 0 0 16px;
		border-left: 2px solid var(--line);
	}
	.items li {
		position: relative;
		display: flex;
		flex-wrap: wrap;
		gap: 10px;
		align-items: baseline;
		padding: 5px 0 5px 10px;
	}
	.dot {
		position: absolute;
		left: -23px;
		top: 11px;
		width: 12px;
		height: 12px;
		border-radius: 50%;
		border: 2px solid var(--bg);
	}
	.date {
		min-width: 100px;
	}
	.label {
		font-size: 0.8rem;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		min-width: 110px;
	}
	.map {
		opacity: 0;
	}
	.items li:hover .map {
		opacity: 1;
	}
</style>
