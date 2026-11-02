<script lang="ts">
	import { TIMELINE_RULES, ruleTitle, type TimelineRule } from '$lib/timelineCleanup';

	let { data } = $props();
	const rules = Object.keys(TIMELINE_RULES) as TimelineRule[];
</script>

<svelte:head><title>Timelines · Admin</title></svelte:head>

<h1>Timelines</h1>
<p class="muted">
	Pages whose conditions, lifespan and footprint disagree. Open one to review the proposed fixes; nothing changes until you apply
	them. Events, media, people and organizations aren't checked.
</p>

{#if data.total}
	<div class="filters">
		<a href="?" class:on={!data.rule}>All <span class="n">{data.total}</span></a>
		{#each rules as r (r)}
			{#if data.counts[r]}
				<a href="?rule={r}" class:on={data.rule === r} title={TIMELINE_RULES[r].why}>{TIMELINE_RULES[r].title} <span class="n">{data.counts[r]}</span></a>
			{/if}
		{/each}
	</div>
	<table class="list">
		<thead><tr><th>Page</th><th>Kind</th><th>Fixes</th><th></th></tr></thead>
		<tbody>
			{#each data.rows as r (r.entity_id)}
				<tr>
					<td><a href="/e/{r.slug}">{r.name}</a></td>
					<td class="muted small">{r.kind}</td>
					<td class="small">{r.fixes} · <span class="muted">{r.rules.map(ruleTitle).join(', ')}</span></td>
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
