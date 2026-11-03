<script lang="ts">
	import type { TimelineRow } from '$lib/types';
	import { formatFuzzy } from '$lib/time';
	import ConfidenceMark from './ConfidenceMark.svelte';

	let {
		rows,
		highlightYear = null,
		sourceIndex = {}
	}: {
		rows: TimelineRow[];
		highlightYear?: number | null;
		/** source id → footnote number */
		sourceIndex?: Record<string, number>;
	} = $props();

	const dated = $derived(rows.filter((r) => r.at));
	const undated = $derived(rows.filter((r) => !r.at));

	const isNow = (r: TimelineRow) => {
		if (highlightYear == null || !r.at) return false;
		const from = Number(r.at.slice(0, 4));
		const to = r.until ? Number(r.until.slice(0, 4)) : from;
		return highlightYear >= from && highlightYear <= Math.max(from, to);
	};
	const fmtUntil = (r: TimelineRow) =>
		r.until && r.until !== r.at ? ` – ${formatFuzzy(r.until, r.until_precision)}` : '';
</script>

{#snippet item(r: TimelineRow)}
	<li class:now={isNow(r)} class={r.category}>
		<span class="dot" style:background={r.color}></span>
		<div class="when date">
			{#if r.at}{formatFuzzy(r.at, r.at_precision)}{fmtUntil(r)}{:else}undated{/if}
		</div>
		<div class="what">
			{r.label}
			{#if r.ref_slug}
				{r.category === 'event' ? ':' : ''}
				<a href="/e/{r.ref_slug}">{r.ref_name}</a>
			{/if}
			<ConfidenceMark confidence={r.confidence} />
			{#if r.source_id && sourceIndex[r.source_id]}
				<sup><a href="#source-{sourceIndex[r.source_id]}">[{sourceIndex[r.source_id]}]</a></sup>
			{/if}
			{#if r.description}<p class="desc">{r.description}</p>{/if}
		</div>
	</li>
{/snippet}

{#if rows.length === 0}
	<p class="muted">No dated facts yet.</p>
{:else}
	<ol class="timeline">
		{#each dated as r (r.fact_table + r.fact_id + r.label)}
			{@render item(r)}
		{/each}
	</ol>
	{#if undated.length}
		<details class="undated">
			<summary class="muted small">{undated.length} undated fact{undated.length === 1 ? '' : 's'}</summary>
			<ol class="timeline">
				{#each undated as r (r.fact_table + r.fact_id + r.label)}
					{@render item(r)}
				{/each}
			</ol>
		</details>
	{/if}
{/if}

<style>
	.timeline {
		list-style: none;
		margin: 0;
		padding: 0 0 0 14px;
		border-left: 2px solid var(--line);
	}
	li {
		position: relative;
		display: grid;
		grid-template-columns: 150px 1fr;
		gap: 12px;
		padding: 6px 0 6px 12px;
		font-size: 0.92rem;
	}
	li.now {
		background: linear-gradient(90deg, rgba(224, 162, 58, 0.12), transparent 80%);
	}
	.dot {
		position: absolute;
		left: -21px;
		top: 12px;
		width: 12px;
		height: 12px;
		border-radius: 50%;
		border: 2px solid var(--bg);
	}
	li.lifespan .what {
		font-weight: 600;
	}
	.desc {
		margin: 3px 0 0;
		font-size: 0.88rem;
		line-height: 1.45;
		color: var(--ink-2);
		white-space: pre-line;
	}
	li.geometry,
	li.attribute {
		color: var(--ink-2);
		font-size: 0.86rem;
	}
	.when {
		padding-top: 1px;
	}
	.undated {
		margin-top: 10px;
	}
	@media (max-width: 600px) {
		li {
			grid-template-columns: 1fr;
			gap: 0;
		}
	}
</style>
