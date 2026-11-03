<script lang="ts">
	import Badge from '$lib/components/Badge.svelte';
	import KindBadge from '$lib/components/KindBadge.svelte';

	let { data } = $props();
	const total = $derived(Object.values(data.statusCounts).reduce((a, b) => a + b, 0));
	const statusOf = (id: string | null) => data.vocab.articleStatuses.find((s) => s.id === id);
	const kinds = $derived(data.vocab.kinds.filter((k) => data.kindPages[k.id]));
	const kindLabel = $derived(data.vocab.kinds.find((k) => k.id === data.kind));
	/** a link within the current kind tab */
	const href = (p: Record<string, string>) => {
		const q = new URLSearchParams({ ...(data.kind ? { kind: data.kind } : {}), ...p }).toString();
		return q ? `?${q}` : '/maintenance';
	};
	// on a kind's tab, only the queues that have something in them
	const queues = $derived(Object.entries(data.issues).filter(([k]) => !data.kind || data.issueCounts[k] > 0));
</script>

<svelte:head><title>Maintenance · {data.settings.site_name}</title></svelte:head>

<div class="page">
	<h1>Maintenance</h1>
	<p class="muted">
		Article status is tracked over time, and gaps in the data are detected automatically from the facts. Pick a queue and fix something.
	</p>

	<nav class="kinds" aria-label="Kind of page">
		<a href="/maintenance" class:on={!data.kind}>All</a>
		{#each kinds as k (k.id)}
			<a href="?kind={k.id}" class:on={data.kind === k.id} title="{data.kindFlagged[k.id] ?? 0} of {data.kindPages[k.id]} pages need something">
				{k.plural}
				{#if data.kindFlagged[k.id]}<span class="count">{data.kindFlagged[k.id]}</span>{/if}
			</a>
		{/each}
	</nav>

	<h2>Article status{#if kindLabel}<span class="muted">&nbsp;· {kindLabel.plural}</span>{/if}</h2>
	<div class="bar" role="img" aria-label="Article status distribution">
		{#each data.vocab.articleStatuses as s (s.id)}
			{#if data.statusCounts[s.id]}
				<a
					href={href({ status: s.id })}
					style:flex={data.statusCounts[s.id]}
					style:background={s.color}
					title="{s.label}: {data.statusCounts[s.id]}"
				></a>
			{/if}
		{/each}
	</div>
	<div class="row legend">
		{#each data.vocab.articleStatuses as s (s.id)}
			<a href={href({ status: s.id })} class:on={data.status === s.id}>
				<Badge color={s.color} label="{s.label} · {data.statusCounts[s.id] ?? 0}" />
			</a>
		{/each}
		<span class="muted small">{total} articles</span>
	</div>
	{#if data.kind === 'media'}<p class="hint">A picture or document can be a stub: media pages aren't flagged for short articles.</p>{/if}

	<h2>Work queues</h2>
	<div class="queues">
		{#if (data.perms ?? []).includes('view_private') && !data.kind}
			<a class="queue card" href="/browse?visibility=private&sort=recent">
				<span class="n">{data.privateCount}</span>
				<span>Private drafts awaiting publication</span>
			</a>
		{/if}
		{#each queues as [k, label] (k)}
			<a class="queue card" class:on={data.issue === k} href={href({ issue: k })}>
				<span class="n">{data.issueCounts[k]}</span>
				<span>{label}</span>
			</a>
		{:else}
			<p class="muted">Nothing flagged for {kindLabel?.plural.toLowerCase() ?? 'these pages'}.</p>
		{/each}
	</div>

	<h2>
		{#if data.issue}{data.issues[data.issue]}{:else if data.status}Articles marked “{statusOf(data.status)?.label}”{:else}Least recently edited{/if}
		{#if kindLabel}<span class="muted">· {kindLabel.plural}</span>{/if}
		{#if data.issue || data.status}<a class="small" href={href({})}>clear</a>{/if}
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
						{#each r.issues as i (i)}<a href={href({ issue: i })} class="tag">{data.issues[i] ?? i}</a>{/each}
					</td>
				</tr>
			{/each}
		</tbody>
	</table>
</div>

<style>
	.kinds {
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
		margin: 14px 0 4px;
		border-bottom: 1px solid var(--line);
	}
	.kinds a {
		display: inline-flex;
		gap: 6px;
		align-items: baseline;
		padding: 6px 12px;
		border: 1px solid transparent;
		border-bottom: 0;
		border-radius: var(--radius) var(--radius) 0 0;
		color: var(--ink-2);
		margin-bottom: -1px;
	}
	.kinds a:hover {
		text-decoration: none;
		color: var(--ink);
	}
	.kinds a.on {
		color: var(--ink);
		background: var(--panel);
		border-color: var(--line);
	}
	.kinds .count {
		font-size: 0.72rem;
		color: var(--amber);
	}
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
