<script lang="ts">
	import { enhance } from '$app/forms';
	import ConfidenceMark from '$lib/components/ConfidenceMark.svelte';
	import { formatFuzzy, formatRange } from '$lib/time';

	let { data, form } = $props();
	const s = $derived(data.source);
	const owner = $derived(s.entity_id ? data.entities[s.entity_id] : null);
</script>

<svelte:head><title>{s.title} · Sources · {data.settings.site_name}</title></svelte:head>

<div class="page narrow">
	<div class="eyebrow">Source · {s.kind.replace('_', ' ')}</div>
	<h1>{s.title}</h1>
	{#if form?.error}<p class="notice error">{form.error}</p>{/if}
	{#if form?.ok}<p class="notice ok">{form.ok}</p>{/if}
	{#if s.entity_id}
		<div class="notice owner">
			Made for {#if owner}<a href="/e/{owner.slug}">{owner.name}</a>{:else}one page{/if}: only that page's forms and article offer it.
			{#if data.user}
				<form method="post" action="?/addToLibrary" use:enhance>
					<button class="ghost">Add to library</button>
				</form>
			{/if}
		</div>
	{/if}
	<table class="meta">
		<tbody>
			{#if s.author}<tr><th>Author</th><td>{s.author}</td></tr>{/if}
			{#if s.publisher}<tr><th>Publisher</th><td>{s.publisher}</td></tr>{/if}
			{#if s.published_on}<tr><th>Published</th><td>{formatFuzzy(s.published_on, s.published_precision)}</td></tr>{/if}
			{#if s.repository}<tr><th>Repository</th><td>{s.repository}</td></tr>{/if}
			{#if s.call_number}<tr><th>Call number</th><td class="mono">{s.call_number}</td></tr>{/if}
			{#if s.url}<tr><th>URL</th><td><a href={s.url} target="_blank" rel="noopener">{s.url}</a></td></tr>{/if}
			{#if s.archive_url}<tr><th>Archived</th><td><a href={s.archive_url} target="_blank" rel="noopener">{s.archive_url}</a></td></tr>{/if}
		</tbody>
	</table>
	{#if s.notes}<p>{s.notes}</p>{/if}

	{#if data.articles.length}
		<h2>Articles citing this source ({data.articles.length})</h2>
		<ul class="plain-list">
			{#each data.articles as id (id)}
				{@const e = data.entities[id]}
				{#if e}<li><a href="/e/{e.slug}">{e.name}</a></li>{/if}
			{/each}
		</ul>
	{/if}

	<h2>Facts citing this source ({data.facts.length})</h2>
	<ul class="plain-list">
		{#each data.facts as f (f.fact_table + f.id)}
			{@const e = data.entities[f.entity_id]}
			{@const o = f.other_id ? data.entities[f.other_id] : null}
			<li>
				{#if e}<a href="/e/{e.slug}">{e.name}</a>{/if}
				· {f.summary}{#if o} → <a href="/e/{o.slug}">{o.name}</a>{/if}
				<ConfidenceMark confidence={f.confidence} />
				<div class="small muted">
					{formatRange(f.valid_from, f.valid_from_precision, f.valid_to, f.valid_to_precision) || 'undated'}
					{#if f.source_detail}· {f.source_detail}{/if}
				</div>
			</li>
		{:else}
			<li class="muted">Nothing cites this yet.</li>
		{/each}
	</ul>
</div>

<style>
	.owner {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 10px;
		flex-wrap: wrap;
	}
	.meta th {
		width: 140px;
		text-transform: none;
		letter-spacing: 0;
	}
</style>
