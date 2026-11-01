<script lang="ts">
	import ConfidenceMark from '$lib/components/ConfidenceMark.svelte';
	import { formatFuzzy, formatRange } from '$lib/time';

	let { data } = $props();
	const s = $derived(data.source);
</script>

<svelte:head><title>{s.title} · Sources · {data.settings.site_name}</title></svelte:head>

<div class="page narrow">
	<div class="eyebrow">Source · {s.kind.replace('_', ' ')}</div>
	<h1>{s.title}</h1>
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
	.meta th {
		width: 140px;
		text-transform: none;
		letter-spacing: 0;
	}
</style>
