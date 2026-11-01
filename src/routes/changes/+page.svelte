<script lang="ts">
	let { data } = $props();
	const LABEL: Record<string, string> = {
		entities: 'page',
		entity_names: 'name',
		entity_geometries: 'shape',
		entity_states: 'condition',
		entity_attributes: 'attribute',
		addresses: 'address',
		relations: 'relation',
		event_details: 'event details',
		media_items: 'media'
	};
	const ago = (s: string) => {
		const m = Math.round((Date.now() - new Date(s).getTime()) / 60000);
		if (m < 60) return `${m}m ago`;
		if (m < 1440) return `${Math.round(m / 60)}h ago`;
		return new Date(s).toLocaleDateString();
	};
	const what = (r: { activity: string; action: string; detail: string | null; data: Record<string, unknown> | null }) => {
		if (r.activity === 'revision') return `edited the article${r.detail ? `: “${r.detail}”` : ''}`;
		if (r.activity === 'status') return `moved the article ${r.data?.from ?? 'new'} → ${r.data?.to}${r.detail ? `: “${r.detail}”` : ''}`;
		const verb = r.action === 'INSERT' ? 'added' : r.action === 'DELETE' ? 'removed' : 'changed';
		const d = r.data ?? {};
		const val = d.name ?? d.status ?? d.key ?? d.predicate ?? d.role ?? '';
		return `${verb} ${LABEL[r.detail ?? ''] ?? r.detail}${val ? ` (${val})` : ''}`;
	};
</script>

<svelte:head><title>Recent changes · {data.settings.site_name}</title></svelte:head>

<div class="page">
	<div class="spread">
		<h1>Recent changes</h1>
		<div class="row">
			<a class="btn" class:primary={!data.filter} href="/changes">All</a>
			<a class="btn" class:primary={data.filter === 'prose'} href="?only=prose">Articles</a>
			<a class="btn" class:primary={data.filter === 'facts'} href="?only=facts">Facts</a>
		</div>
	</div>
	{#if data.error}<p class="notice error">{data.error}</p>{/if}
	<ul class="plain-list">
		{#each data.rows as r (r.activity + r.id)}
			{@const e = r.entity_id ? data.entities[r.entity_id] : null}
			<li class="row">
				<span class="date when">{ago(r.created_at)}</span>
				<span class="who">{r.actor_id ? (data.actors[r.actor_id] ?? 'someone') : 'system'}</span>
				<span>{what(r)}</span>
				<span>on {#if e}<a href="/e/{e.slug}">{e.name}</a>{:else}<span class="muted">a deleted page</span>{/if}</span>
			</li>
		{:else}
			<li class="muted">Nothing yet.</li>
		{/each}
	</ul>
</div>

<style>
	.when {
		min-width: 80px;
		color: var(--muted);
	}
	.who {
		font-weight: 600;
	}
</style>
