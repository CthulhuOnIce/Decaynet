<script lang="ts">
	import KindBadge from '$lib/components/KindBadge.svelte';
	import { slugifyClient } from '$lib/slug';
	import { yearOf } from '$lib/time';

	let { data } = $props();
</script>

<svelte:head><title>Search: {data.q} · Decaynet</title></svelte:head>

<div class="page narrow">
	<h1>Search</h1>
	<form method="get" class="row">
		<input name="q" value={data.q} placeholder="Hotel Gary, Genesis Towers, Broadway…" style="flex: 1" />
		<input type="hidden" name="go" value="0" />
		<button class="primary">Search</button>
	</form>
	<p class="hint">Matches current <em>and historic</em> names, so “Genesis Towers” finds Hotel Gary.</p>

	{#if data.q}
		<ul class="plain-list results">
			{#each data.hits as h (h.id)}
				<li>
					<a href="/e/{h.slug}"><strong>{h.name}</strong></a>
					{#if h.matched_name !== h.name}<span class="muted">· matched “{h.matched_name}”</span>{/if}
					<div class="row small">
						<KindBadge kind={h.kind} />
						{#if h.exists_from || h.exists_to}<span class="date">{yearOf(h.exists_from) ?? '?'} – {yearOf(h.exists_to) ?? ''}</span>{/if}
					</div>
				</li>
			{:else}
				<li class="muted">No pages match “{data.q}”.</li>
			{/each}
		</ul>
		{#if data.user}
			<p><a class="btn" href="/new?slug={slugifyClient(data.q)}">Create “{data.q}”</a></p>
		{/if}
	{/if}
</div>

<style>
	.results {
		margin-top: 18px;
	}
	.results li {
		padding: 10px 0;
	}
</style>
