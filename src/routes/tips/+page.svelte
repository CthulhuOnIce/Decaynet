<script lang="ts">
	let { data } = $props();
	const TABS = [
		['open', 'Open'],
		['new', 'New'],
		['reviewing', 'Reviewing'],
		['accepted', 'Accepted'],
		['rejected', 'Rejected'],
		['spam', 'Spam'],
		['all', 'All']
	];
	const count = (k: string) =>
		k === 'open' ? (data.counts.new ?? 0) + (data.counts.reviewing ?? 0) : k === 'all' ? Object.values(data.counts).reduce((a, b) => a + b, 0) : (data.counts[k] ?? 0);
	const COLORS: Record<string, string> = { new: '#e0a23a', reviewing: '#8fb3c9', accepted: '#7fae6a', rejected: '#968a7a', spam: '#a33a1f' };
</script>

<svelte:head><title>Tips · {data.settings.site_name}</title></svelte:head>

<div class="page">
	<div class="spread">
		<h1>Tips</h1>
		<a class="btn ghost" href="/admin/settings">Tip settings</a>
	</div>
	<nav class="row tabs">
		{#each TABS as [k, l] (k)}
			<a class="btn" class:primary={data.status === k} href="?status={k}">{l} <span class="muted">{count(k)}</span></a>
		{/each}
	</nav>

	<ul class="plain-list">
		{#each data.tips as t (t.id)}
			<li>
				<a class="tip" href="/tips/{t.id}">
					<span class="badge" style:color={COLORS[t.status]}>{t.status}</span>
					<strong>{t.subject ?? t.body.slice(0, 80)}</strong>
					{#if t.about_name}<span class="muted">· about {t.about_name}</span>{:else if t.about_text}<span class="muted">· {t.about_text}</span>{/if}
					{#if t.images.length}<span class="muted small">· 🖼 {t.images.length}</span>{/if}
					{#if t.location_geojson}<span class="muted small">· 📍</span>{/if}
					<span class="date when">{new Date(t.created_at).toLocaleString()}</span>
				</a>
				{#if t.subject}<p class="muted small excerpt">{t.body.slice(0, 200)}{t.body.length > 200 ? '…' : ''}</p>{/if}
			</li>
		{:else}
			<li class="muted">No tips here.</li>
		{/each}
	</ul>
</div>

<style>
	.tabs {
		margin: 10px 0 18px;
	}
	.tip {
		display: flex;
		gap: 8px;
		align-items: baseline;
		flex-wrap: wrap;
		color: var(--ink);
	}
	.when {
		margin-left: auto;
		color: var(--muted);
	}
	.excerpt {
		margin: 4px 0 0;
	}
</style>
