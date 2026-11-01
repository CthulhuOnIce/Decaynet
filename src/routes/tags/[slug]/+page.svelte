<script lang="ts">
	import KindBadge from '$lib/components/KindBadge.svelte';
	import { formatRange } from '$lib/time';

	let { data } = $props();
	const t = $derived(data.tag);
</script>

<svelte:head><title>{t.label} · Tags · Decaynet</title></svelte:head>

<div class="page narrow">
	<div class="eyebrow">
		<a href="/tags">{t.facet_label}</a>
		{#each data.ancestors as a (a.id)} › <a href="/tags/{a.slug}">{a.label}</a>{/each}
	</div>
	<h1>{t.label}</h1>
	{#if t.description}<p class="muted">{t.description}</p>{/if}

	{#if data.children.length}
		<p class="row small">
			Sub-traits:
			{#each data.children as c (c.id)}<a class="btn ghost" href="/tags/{c.slug}">{c.label} <span class="muted">{c.total_uses}</span></a>{/each}
		</p>
	{/if}

	<form method="get" class="row filter">
		<label for="y" class="muted">Only pages with this trait in year</label>
		<input id="y" name="y" type="number" min="1700" max="2100" value={data.year ?? ''} style="width: 100px" />
		<button>Filter</button>
		{#if data.year}<a href="?">all time</a>{/if}
		<a class="btn primary" href="/?y={data.year ?? 1955}&tag={t.slug}">Show on map</a>
	</form>

	<ul class="plain-list">
		{#each data.rows as r, i (r.id + i)}
			<li>
				<a href="/e/{r.slug}"><strong>{r.name}</strong></a>
				<KindBadge kind={r.kind} />
				{#if r.via_tag !== t.slug}<span class="muted small">via <a href="/tags/{r.via_tag}">{r.via_label}</a></span>{/if}
				<div class="date">{formatRange(r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision) || 'undated'}</div>
			</li>
		{:else}
			<li class="muted">Nothing tagged {t.label}{data.year ? ` in ${data.year}` : ''} yet.</li>
		{/each}
	</ul>
</div>

<style>
	.filter {
		margin: 16px 0;
	}
	.filter label {
		margin: 0;
	}
	.date {
		font-size: 0.75rem;
		color: var(--muted);
	}
</style>
