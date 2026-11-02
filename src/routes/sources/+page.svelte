<script lang="ts">
	import { enhance } from '$app/forms';
	import { formatFuzzy } from '$lib/time';

	import { SOURCE_KINDS as KINDS } from '$lib/sources';

	let { data, form } = $props();
	let filter = $state('');
	// Library = shared sources; page sources were made on one page for its facts or article
	let view = $state<'library' | 'page'>('library');
	const pageCount = $derived(data.sources.filter((s) => s.entity_id).length);
	const shown = $derived(
		data.sources.filter(
			(s) =>
				(view === 'library' ? !s.entity_id : !!s.entity_id) &&
				(!filter || `${s.title} ${s.author ?? ''} ${s.repository ?? ''} ${s.page?.name ?? ''}`.toLowerCase().includes(filter.toLowerCase()))
		)
	);
</script>

<svelte:head><title>Sources · {data.settings.site_name}</title></svelte:head>

<div class="page">
	<h1>Sources</h1>
	<p class="muted">
		Every fact and article can cite a source plus a page/frame detail. City directories, Sanborn maps and the Post-Tribune are gold.
		Sources here are shared by every page; a one-off source can also be made right on a page while adding a fact or writing its article.
	</p>

	<div class="grid-2">
		<div>
			<div class="seg">
				<button class:on={view === 'library'} onclick={() => (view = 'library')}>Library</button>
				<button class:on={view === 'page'} onclick={() => (view = 'page')}>Page sources ({pageCount})</button>
			</div>
			<input placeholder="Filter sources…" bind:value={filter} />
			<ul class="plain-list">
				{#each shown as s (s.id)}
					<li>
						<a href="/sources/{s.id}"><strong>{s.title}</strong></a>
						<span class="muted small">· {s.kind.replace('_', ' ')}</span>
						<div class="small muted">
							{[s.author, s.publisher, s.repository].filter(Boolean).join(' · ')}
							{#if s.published_on}· {formatFuzzy(s.published_on, s.published_precision)}{/if}
						</div>
						<div class="small">
							{data.counts[s.id] ?? 0} facts cite this
							{#if s.page}· made for <a href="/e/{s.page.slug}">{s.page.name}</a>{/if}
						</div>
					</li>
				{:else}
					<li class="muted">{view === 'library' ? 'No sources yet.' : 'No page sources yet.'}</li>
				{/each}
			</ul>
		</div>

		{#if data.user}
			<form method="post" action="?/create" class="card stack" use:enhance>
				<h3>Add a source to the library</h3>
				{#if form?.error}<p class="notice error">{form.error}</p>{/if}
				{#if form?.ok}<p class="notice ok">Added.</p>{/if}
				<div><label for="t">Title</label><input id="t" name="title" required /></div>
				<div class="fields">
					<div>
						<label for="k">Kind</label>
						<select id="k" name="kind">{#each KINDS as k (k)}<option value={k}>{k.replace('_', ' ')}</option>{/each}</select>
					</div>
					<div><label for="p">Published</label><input id="p" name="published_on" placeholder="1926 · May 1926" /></div>
				</div>
				<div><label for="a">Author</label><input id="a" name="author" /></div>
				<div><label for="pub">Publisher</label><input id="pub" name="publisher" /></div>
				<div><label for="u">URL</label><input id="u" name="url" type="url" /></div>
				<div><label for="au">Archived copy URL</label><input id="au" name="archive_url" type="url" /></div>
				<div class="fields">
					<div><label for="r">Repository</label><input id="r" name="repository" placeholder="City or university archive" /></div>
					<div><label for="c">Call number</label><input id="c" name="call_number" /></div>
				</div>
				<div><label for="n">Notes</label><textarea id="n" name="notes" rows="3" style="min-height: 60px"></textarea></div>
				<button class="primary">Add source</button>
			</form>
		{/if}
	</div>
</div>

<style>
	.seg {
		display: flex;
		gap: 2px;
		margin-bottom: 8px;
	}
	.seg button {
		flex: 1;
		justify-content: center;
	}
	.seg button.on {
		background: var(--rust);
		border-color: var(--rust);
		color: #fff;
	}
</style>
