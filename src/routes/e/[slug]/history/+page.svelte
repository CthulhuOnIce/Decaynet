<script lang="ts">
	let { data } = $props();
	const when = (s: string) => new Date(s).toLocaleString();
	const TABLES: Record<string, string> = {
		entities: 'page',
		entity_names: 'name',
		entity_geometries: 'shape',
		entity_states: 'condition',
		entity_attributes: 'attribute',
		addresses: 'address',
		relations: 'relation',
		event_details: 'event details',
		media_items: 'media file'
	};
	const describe = (c: { table_name: string; new_data: Record<string, unknown> | null; old_data: Record<string, unknown> | null }) => {
		const d = c.new_data ?? c.old_data ?? {};
		return String(d.name ?? d.status ?? d.key ?? d.predicate ?? d.role ?? d.house_number ?? d.event_type ?? d.media_type ?? '');
	};
</script>

<svelte:head><title>History: {data.entity.name} · {data.settings.site_name}</title></svelte:head>

<div class="page">
	<div class="eyebrow">History</div>
	<h1><a href="/e/{data.entity.slug}">{data.entity.name}</a></h1>
	<p class="muted">
		Two clocks run on this wiki. <em>Valid time</em> is when something was true in the world (on the facts themselves).
		<em>Record time</em> is when someone wrote it down, shown here.
	</p>

	<div class="grid-2">
		<div>
			<h2>Article revisions</h2>
			{#if data.revisions.length}
				<ul class="plain-list">
					{#each data.revisions as r, i (r.id)}
						<li>
							<div class="spread">
								<div>
									<strong>{r.edit_summary ?? '(no summary)'}</strong>
									<span class="muted small">by {r.author?.display_name ?? 'system'} · {r.status}</span>
								</div>
								<span class="date">{when(r.created_at)}</span>
							</div>
							<details>
								<summary class="muted small">
									{r.body.length.toLocaleString()} chars
									{#if data.revisions[i + 1]}({r.body.length - data.revisions[i + 1].body.length >= 0 ? '+' : ''}{r.body.length - data.revisions[i + 1].body.length}){/if}
								</summary>
								<pre class="body">{r.body}</pre>
							</details>
						</li>
					{/each}
				</ul>
			{:else}
				<p class="muted">No prose written yet.</p>
			{/if}

			<h2>Fact changes</h2>
			<table>
				<thead><tr><th>When</th><th>Who</th><th>What</th></tr></thead>
				<tbody>
					{#each data.changes as c (c.id)}
						<tr>
							<td class="date">{when(c.created_at)}</td>
							<td>{c.actor_id ? (data.actors[c.actor_id] ?? 'someone') : 'system'}</td>
							<td>
								<span class="op op-{c.op.toLowerCase()}">{c.op.toLowerCase()}</span>
								{TABLES[c.table_name] ?? c.table_name}
								<span class="muted">{describe(c)}</span>
								<details>
									<summary class="muted small">data</summary>
									<pre>{JSON.stringify(c.new_data ?? c.old_data, null, 2)}</pre>
								</details>
							</td>
						</tr>
					{:else}
						<tr><td colspan="3" class="muted">No changes recorded.</td></tr>
					{/each}
				</tbody>
			</table>
		</div>

		<aside class="card">
			<h3>Article status</h3>
			<ul class="plain-list small">
				{#each data.statusEvents as s (s.id)}
					<li>
						<div>{s.from_status ?? 'new'} → <strong>{s.to_status}</strong></div>
						<div class="muted">{s.actor?.display_name ?? 'system'} · {when(s.created_at)}</div>
						{#if s.note}<div>{s.note}</div>{/if}
					</li>
				{/each}
			</ul>
		</aside>
	</div>
</div>

<style>
	pre {
		white-space: pre-wrap;
		font-family: var(--mono);
		font-size: 0.78rem;
		background: var(--bg-2);
		padding: 10px;
		border-radius: var(--radius);
		max-height: 360px;
		overflow: auto;
	}
	.op {
		font-family: var(--mono);
		font-size: 0.72rem;
		padding: 1px 6px;
		border-radius: 3px;
		margin-right: 4px;
	}
	.op-insert {
		background: rgba(127, 174, 106, 0.2);
		color: var(--moss);
	}
	.op-update {
		background: rgba(224, 162, 58, 0.2);
		color: var(--amber);
	}
	.op-delete {
		background: rgba(224, 85, 43, 0.2);
		color: var(--danger);
	}
</style>
