<script lang="ts">
	import { enhance } from '$app/forms';
	import TagSelect from '$lib/components/TagSelect.svelte';

	let { data, form } = $props();
	const byFacet = $derived(
		data.vocab.tagFacets.map((f) => ({ facet: f, tags: data.tags.filter((t) => t.facet === f.id) }))
	);
</script>

<svelte:head><title>Tags · Decaynet</title></svelte:head>

<div class="page">
	<h1>Tags & traits</h1>
	<p class="muted" style="max-width: 75ch">
		A tree of traits that can be attached to any page (businesses, buildings, articles, photos), each with
		its own dates. Tagging a specific sub-trait implies its parents, so <em>Food & drink</em> includes every soul-food
		place and diner.
	</p>

	<div class="grid-2">
		<div class="facets">
			{#each byFacet as { facet, tags } (facet.id)}
				<section class="card" style:--c={facet.color}>
					<h2>{facet.label}</h2>
					{#if facet.description}<p class="muted small">{facet.description}</p>{/if}
					<ul class="tree">
						{#each tags as t (t.id)}
							<li style:padding-left="{t.depth * 18}px">
								<a href="/tags/{t.slug}">{t.label}</a>
								<span class="count" title="{t.direct_uses} tagged directly, {t.total_uses} including sub-traits">
									{t.total_uses}
								</span>
							</li>
						{:else}
							<li class="muted small">No tags yet.</li>
						{/each}
					</ul>
				</section>
			{/each}
		</div>

		{#if data.user}
			<form method="post" action="?/create" class="card stack" use:enhance>
				<h3>New tag</h3>
				{#if form?.error}<p class="notice error">{form.error}</p>{/if}
				{#if form?.ok}<p class="notice ok">Created.</p>{/if}
				<div><label for="l">Label</label><input id="l" name="label" required placeholder="Barbershop" /></div>
				<div>
					<label for="p">Sub-trait of</label>
					<TagSelect id="p" name="parent_id" tags={data.tags} placeholder="(top level)" />
				</div>
				<div>
					<label for="f">Facet (top-level tags only)</label>
					<select id="f" name="facet">
						<option value="">—</option>
						{#each data.vocab.tagFacets as f (f.id)}<option value={f.id}>{f.label}</option>{/each}
					</select>
				</div>
				<div><label for="d">Description</label><input id="d" name="description" /></div>
				<button class="primary">Create tag</button>
			</form>
		{/if}
	</div>
</div>

<style>
	.facets {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
		gap: 14px;
		align-items: start;
	}
	.facets h2 {
		font-size: 1.1rem;
		border-left: 4px solid var(--c);
		padding-left: 8px;
	}
	.tree {
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.tree li {
		display: flex;
		justify-content: space-between;
		padding: 3px 0;
		font-size: 0.9rem;
	}
	.count {
		font-family: var(--mono);
		font-size: 0.75rem;
		color: var(--muted);
	}
</style>
