<script lang="ts">
	let { data } = $props();
	const p = $derived(data.person);
	const verbs: Record<string, string> = { INSERT: 'added', UPDATE: 'changed', DELETE: 'removed', EDIT: 'edited article', STATUS: 'changed status' };
</script>

<svelte:head><title>{p.display_name} · {data.settings.site_name}</title></svelte:head>

<div class="page narrow">
	<div class="eyebrow">{p.role} · since {p.created_at.slice(0, 10)}</div>
	<h1>{p.display_name}</h1>
	{#if p.bio}<p>{p.bio}</p>{/if}
	{#if p.website}<p><a href={p.website} rel="noopener nofollow" target="_blank">{p.website}</a></p>{/if}

	<h2>Recent contributions ({data.activity.length})</h2>
	<ul class="plain-list">
		{#each data.activity as a (a.activity + a.id)}
			{@const e = a.entity_id ? data.entities[a.entity_id] : null}
			<li>
				<span class="date">{a.created_at.slice(0, 16).replace('T', ' ')}</span>
				{verbs[a.action] ?? a.action}
				{#if a.activity === 'fact'}<span class="muted">{a.detail?.replace('entity_', '')}</span>{/if}
				on {#if e}<a href="/e/{e.slug}">{e.name}</a>{:else}<span class="muted">a deleted page</span>{/if}
			</li>
		{:else}
			<li class="muted">Nothing yet.</li>
		{/each}
	</ul>
</div>
