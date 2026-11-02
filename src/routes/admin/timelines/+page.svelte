<script lang="ts">
	import { TIMELINE_SECTIONS, sectionTitle, type TimelineSection } from '$lib/timelineCleanup';

	let { data } = $props();
	const sections = Object.keys(TIMELINE_SECTIONS) as TimelineSection[];
</script>

<svelte:head><title>Timelines · Admin</title></svelte:head>

<h1>Timelines</h1>
<p class="muted">
	Pages whose conditions, shapes, addresses or relations don't agree with their lifespan, or have loose ends: no condition
	recorded, a tenant still listed after demolition, an undated point. Open one to review; nothing changes until you apply.
</p>

{#if data.total}
	<div class="filters">
		<a href="?" class:on={!data.section}>All <span class="n">{data.total}</span></a>
		{#each sections as s (s)}
			{#if data.counts[s]}
				<a href="?section={s}" class:on={data.section === s} title={TIMELINE_SECTIONS[s].why}>{TIMELINE_SECTIONS[s].title} <span class="n">{data.counts[s]}</span></a>
			{/if}
		{/each}
	</div>
	<table class="list">
		<thead><tr><th>Page</th><th>Kind</th><th>To review</th><th></th></tr></thead>
		<tbody>
			{#each data.rows as r (r.entity_id)}
				<tr>
					<td><a href="/e/{r.slug}">{r.name}</a></td>
					<td class="muted small">{r.kind}</td>
					<td class="small">
						{#if r.fixes}{r.fixes} fix{r.fixes === 1 ? '' : 'es'}{/if}{#if r.suggestions}{r.fixes ? ' · ' : ''}{r.suggestions} suggestion{r.suggestions === 1 ? '' : 's'}{/if}{#if r.notes}{r.fixes || r.suggestions ? ' · ' : ''}<span class="note">{r.notes} to check</span>{/if}
						<span class="muted"> · {r.sections.map(sectionTitle).join(', ')}</span>
					</td>
					<td class="go"><a class="btn" href="/e/{r.slug}/cleanup">Review</a></td>
				</tr>
			{/each}
		</tbody>
	</table>
{:else}
	<div class="card"><strong>All tidy.</strong> <span class="muted">No page has a timeline fix waiting.</span></div>
{/if}

<style>
	.filters {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		margin: 14px 0;
	}
	.filters a {
		padding: 3px 10px;
		border: 1px solid var(--line-2);
		border-radius: 999px;
		font-size: 0.82rem;
		color: var(--ink-2);
		text-decoration: none;
	}
	.filters a.on {
		border-color: var(--rust);
		color: var(--ink);
	}
	.n {
		color: var(--muted);
		margin-left: 2px;
	}
	.note {
		color: var(--amber);
	}
	.list {
		width: 100%;
	}
	.list td {
		vertical-align: middle;
	}
	.go {
		text-align: right;
	}
	.go .btn {
		padding: 3px 10px;
		font-size: 0.82rem;
	}
</style>
