<script lang="ts">
	import { page } from '$app/state';
	import type { TimelineRow } from '$lib/types';
	import { formatFuzzy } from '$lib/time';
	import ConfidenceMark from './ConfidenceMark.svelte';

	let {
		rows,
		highlightYear = null,
		sourceIndex = {},
		view = undefined
	}: {
		rows: TimelineRow[];
		highlightYear?: number | null;
		/** source id → footnote number */
		sourceIndex?: Record<string, number>;
		/** 'table' or 'bubbles'; default: the site's setting (Admin → Settings → Pages) */
		view?: 'table' | 'bubbles';
	} = $props();

	const style = $derived(view ?? (page.data.settings?.timeline_style === 'bubbles' ? 'bubbles' : 'table'));
	const dated = $derived(rows.filter((r) => r.at));
	const undated = $derived(rows.filter((r) => !r.at));

	const isNow = (r: TimelineRow) => {
		if (highlightYear == null || !r.at) return false;
		const from = Number(r.at.slice(0, 4));
		const to = r.until ? Number(r.until.slice(0, 4)) : from;
		return highlightYear >= from && highlightYear <= Math.max(from, to);
	};
	const until = (r: TimelineRow) => (r.until && r.until !== r.at ? formatFuzzy(r.until, r.until_precision) : null);
	const key = (r: TimelineRow) => r.fact_table + r.fact_id + r.label;
</script>

<!-- a date range wraps only at the dash; each date stays whole -->
{#snippet when(r: TimelineRow)}
	{#if r.at}
		<span class="d">{formatFuzzy(r.at, r.at_precision)}</span>{#if until(r)}<span class="sep">{' – '}</span><span class="d">{until(r)}</span>{/if}
	{:else}
		<span class="d">undated</span>
	{/if}
{/snippet}

{#snippet what(r: TimelineRow)}
	{r.label}{#if r.ref_slug}{r.category === 'event' ? ':' : ''} <a href="/e/{r.ref_slug}">{r.ref_name}</a>{/if}
	<ConfidenceMark confidence={r.confidence} />
	{#if r.source_id && sourceIndex[r.source_id]}
		<sup><a href="#source-{sourceIndex[r.source_id]}">[{sourceIndex[r.source_id]}]</a></sup>
	{/if}
	{#if r.description}<p class="desc">{r.description}</p>{/if}
{/snippet}

{#snippet list(items: TimelineRow[])}
	{#if style === 'bubbles'}
		<ol class="bubbles">
			{#each items as r (key(r))}
				<li class:now={isNow(r)} class={r.category}>
					<div class="stamp">
						<span class="dot" style:background={r.color}></span>
						<span class="when">{@render when(r)}</span>
					</div>
					<div class="bubble" style:--accent={r.color}>{@render what(r)}</div>
				</li>
			{/each}
		</ol>
	{:else}
		<table class="tl-table">
			<colgroup><col class="when-col" /><col /></colgroup>
			<tbody>
				{#each items as r (key(r))}
					<tr class:now={isNow(r)} class={r.category}>
						<td class="when"><span class="dot" style:background={r.color}></span>{@render when(r)}</td>
						<td class="what">{@render what(r)}</td>
					</tr>
				{/each}
			</tbody>
		</table>
	{/if}
{/snippet}

{#if rows.length === 0}
	<p class="muted">No dated facts yet.</p>
{:else}
	<div class="timeline-view {style}">
		{@render list(dated)}
		{#if undated.length}
			<details class="undated">
				<summary class="muted small">{undated.length} undated fact{undated.length === 1 ? '' : 's'}</summary>
				{@render list(undated)}
			</details>
		{/if}
	</div>
{/if}

<style>
	/* ---------------------------------------------------------------- shared */
	.d {
		white-space: nowrap;
	}
	.when {
		font-family: var(--mono);
		font-size: 0.8rem;
		color: var(--ink-2);
	}
	.what {
		overflow-wrap: anywhere;
	}
	.dot {
		display: inline-block;
		width: 11px;
		height: 11px;
		border-radius: 50%;
		border: 2px solid var(--bg);
		flex: none;
	}
	.desc {
		margin: 3px 0 0;
		font-size: 0.88rem;
		line-height: 1.45;
		color: var(--ink-2);
		white-space: pre-line;
	}
	.lifespan > .what,
	.lifespan > .bubble {
		font-weight: 600;
	}
	.geometry,
	.attribute {
		color: var(--ink-2);
	}
	.undated {
		margin-top: 10px;
	}

	/* ---------------------------------------------------------------- table */
	.tl-table {
		width: 100%;
		border-collapse: collapse;
		font-size: 0.92rem;
		/* the date column keeps its width; a long range wraps at its dash instead of squeezing the text */
		table-layout: fixed;
	}
	.when-col {
		width: 10em;
	}
	.tl-table td {
		padding: 6px 8px;
		border-bottom: 1px solid var(--line);
		vertical-align: top;
	}
	.tl-table td.when {
		padding-left: 22px;
		position: relative;
		line-height: 1.5;
	}
	.tl-table .when .dot {
		position: absolute;
		left: 4px;
		top: 10px;
	}
	.tl-table tr.now td {
		background: rgba(224, 162, 58, 0.1);
	}
	.tl-table tr.geometry td,
	.tl-table tr.attribute td {
		font-size: 0.86rem;
	}

	/* ---------------------------------------------------------------- bubbles */
	.bubbles {
		list-style: none;
		margin: 0;
		padding: 0 0 0 7px;
		border-left: 2px solid var(--line);
	}
	.bubbles li {
		position: relative;
		padding: 0 0 14px 0;
	}
	.stamp {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-left: -14px; /* the dot sits on the line */
		padding-top: 2px;
	}
	.stamp .when {
		/* a plain block (not flex), so the spaces around the dash survive; wraps at the dash */
		display: block;
		min-width: 0;
	}
	.bubble {
		position: relative;
		margin: 7px 0 0 18px; /* steps down and in from the dot */
		padding: 7px 11px;
		background: var(--panel);
		border: 1px solid var(--line-2);
		border-left: 3px solid var(--accent, var(--line-2));
		border-radius: var(--radius);
		font-size: 0.92rem;
		line-height: 1.45;
		max-width: 46rem;
	}
	/* the notch pointing back up at the dot */
	.bubble::before {
		content: '';
		position: absolute;
		top: -6px;
		left: 10px;
		width: 10px;
		height: 10px;
		background: var(--panel);
		border-left: 1px solid var(--line-2);
		border-top: 1px solid var(--line-2);
		transform: rotate(45deg);
	}
	.bubbles li.now .bubble {
		background: color-mix(in srgb, var(--amber) 10%, var(--panel));
		border-color: var(--amber);
	}
	.bubbles li.now .bubble::before {
		background: color-mix(in srgb, var(--amber) 10%, var(--panel));
		border-color: var(--amber);
	}
	.bubbles li.geometry .bubble,
	.bubbles li.attribute .bubble {
		font-size: 0.86rem;
	}

	@media (max-width: 600px) {
		.when-col {
			width: 8.5em;
		}
		.bubble {
			margin-left: 10px;
		}
	}
	@media print {
		.tl-table tr,
		.bubbles li {
			break-inside: avoid;
		}
	}
</style>
