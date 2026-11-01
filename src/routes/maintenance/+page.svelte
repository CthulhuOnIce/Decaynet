<script lang="ts">
	import Badge from '$lib/components/Badge.svelte';
	import KindBadge from '$lib/components/KindBadge.svelte';

	let { data } = $props();
	const total = $derived(Object.values(data.statusCounts).reduce((a, b) => a + b, 0));
	const statusOf = (id: string | null) => data.vocab.articleStatuses.find((s) => s.id === id);
</script>

<svelte:head><title>Maintenance · {data.settings.site_name}</title></svelte:head>

<div class="page">
	<h1>Maintenance</h1>
	<p class="muted">
		Article status is tracked over time, and gaps in the data are detected automatically from the facts. Pick a queue and fix something.
	</p>

	<h2>Article status</h2>
	<div class="bar" role="img" aria-label="Article status distribution">
		{#each data.vocab.articleStatuses as s (s.id)}
			{#if data.statusCounts[s.id]}
				<a
					href="?status={s.id}"
					style:flex={data.statusCounts[s.id]}
					style:background={s.color}
					title="{s.label}: {data.statusCounts[s.id]}"
				></a>
			{/if}
		{/each}
	</div>
	<div class="row legend">
		{#each data.vocab.articleStatuses as s (s.id)}
			<a href="?status={s.id}" class:on={data.status === s.id}>
				<Badge color={s.color} label="{s.label} · {data.statusCounts[s.id] ?? 0}" />
			</a>
		{/each}
		<span class="muted small">{total} articles</span>
	</div>

	<h2>Work queues</h2>
	<div class="queues">
		{#each Object.entries(data.issues) as [k, label] (k)}
			<a class="queue card" class:on={data.issue === k} href="?issue={k}">
				<span class="n">{data.issueCounts[k]}</span>
				<span>{label}</span>
			</a>
		{/each}
	</div>

	<h2>
		{#if data.issue}{data.issues[data.issue]}{:else if data.status}Articles marked “{statusOf(data.status)?.label}”{:else}Least recently edited{/if}
		{#if data.issue || data.status}<a class="small" href="/maintenance">clear</a>{/if}
	</h2>
	<table>
		<thead><tr><th>Page</th><th>Kind</th><th>Article</th><th>Facts (cited)</th><th>Issues</th></tr></thead>
		<tbody>
			{#each data.rows as r (r.id)}
				{@const st = statusOf(r.article_status)}
				<tr>
					<td><a href="/e/{r.slug}">{r.name}</a></td>
					<td><KindBadge kind={r.kind} /></td>
					<td>{#if st}<Badge color={st.color} label={st.label} />{/if} <span class="muted small">{r.word_count}w</span></td>
					<td class="mono">{r.fact_count} ({r.sourced_fact_count})</td>
					<td class="issues">
						{#each r.issues as i (i)}<a href="?issue={i}" class="tag">{data.issues[i] ?? i}</a>{/each}
					</td>
				</tr>
			{/each}
		</tbody>
	</table>
</div>

<style>
	.bar {
		display: flex;
		height: 18px;
		border-radius: 999px;
		overflow: hidden;
		gap: 2px;
		background: var(--panel);
	}
	.legend {
		margin-top: 10px;
	}
	.legend a.on :global(.badge) {
		background: rgba(255, 255, 255, 0.08);
	}
	.queues {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
		gap: 10px;
	}
	.queue {
		display: flex;
		gap: 12px;
		align-items: center;
		color: var(--ink);
		padding: 12px 14px;
	}
	.queue:hover {
		text-decoration: none;
		border-color: var(--muted);
	}
	.queue.on {
		border-color: var(--rust);
	}
	.queue .n {
		font-family: var(--serif);
		font-size: 1.6rem;
		font-weight: 700;
		color: var(--amber);
		min-width: 2ch;
	}
	.issues {
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
	}
	.tag {
		font-size: 0.72rem;
		padding: 1px 7px;
		border-radius: 3px;
		background: var(--panel-2);
		color: var(--ink-2);
	}
</style>
