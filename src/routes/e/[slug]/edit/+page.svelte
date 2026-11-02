<script lang="ts">
	import { tick } from 'svelte';
	import { enhance } from '$app/forms';
	import SourceFields from '$lib/components/SourceFields.svelte';
	import { NEW_SOURCE, citeToken, type SourceOption } from '$lib/sources';

	let { data, form } = $props();
	const statuses = $derived(
		data.vocab.articleStatuses.filter(
			(s) => !s.moderator_only || ['moderator', 'admin'].includes(data.profile?.role ?? '')
		)
	);
	const isMod = $derived(['moderator', 'admin'].includes(data.profile?.role ?? ''));

	let body = $state('');
	let status = $state('stub');
	$effect.pre(() => {
		body = form?.body ?? data.article?.body ?? '';
		status = data.article?.status ?? 'stub';
	});
	let tab = $state<'write' | 'preview'>('write');
	let preview = $state('');
	let ta: HTMLTextAreaElement | undefined = $state();

	function insertLink() {
		if (!ta) return;
		const slug = prompt('Page slug to link to (e.g. city-methodist-church)');
		if (!slug) return;
		const sel = body.slice(ta.selectionStart, ta.selectionEnd);
		const text = sel ? `[[${slug}|${sel}]]` : `[[${slug}]]`;
		body = body.slice(0, ta.selectionStart) + text + body.slice(ta.selectionEnd);
	}

	// ---- citations: pick a source (this page's or the library's), or make one for this page
	let citeOpen = $state(false);
	let added = $state<SourceOption[]>([]);
	const allSources = $derived([...data.sources, ...added.filter((a) => !data.sources.some((s) => s.id === a.id))]);
	const pageSources = $derived(allSources.filter((s) => s.entity_id));
	const library = $derived(allSources.filter((s) => !s.entity_id));
	let citeId = $state('');
	let citeDetail = $state('');
	let citeError = $state<string | null>(null);
	let citing = $state(false);
	let citeForm: HTMLFormElement | undefined = $state();

	async function insertCite(id: string) {
		if (!ta || !id || id === NEW_SOURCE) return;
		const at = ta.selectionEnd ?? body.length;
		const token = citeToken(id, citeDetail);
		body = body.slice(0, at) + token + body.slice(at);
		citeDetail = '';
		tab = 'write';
		await tick();
		ta.focus();
		ta.setSelectionRange(at + token.length, at + token.length);
	}
</script>

<svelte:head><title>Editing {data.entity.name} · {data.settings.site_name}</title></svelte:head>

<div class="page narrow">
	<div class="eyebrow">Editing article</div>
	<h1><a href="/e/{data.entity.slug}">{data.entity.name}</a></h1>

	{#if data.article?.locked && !isMod}
		<p class="notice error">This article is locked by a moderator.</p>
	{/if}
	{#if form?.error}<p class="notice error">{form.error}</p>{/if}

	<form
		method="post"
		action="?/save"
		class="stack"
		use:enhance={({ action }) => {
			const isPreview = action.search.includes('preview');
			return async ({ result, update }) => {
				if (isPreview) {
					if (result.type === 'success') preview = String(result.data?.preview ?? '');
					tab = 'preview';
				} else await update({ reset: false });
			};
		}}
	>
		<div class="spread">
			<div class="row tabs" role="tablist">
				<button type="button" role="tab" class:active={tab === 'write'} aria-selected={tab === 'write'} onclick={() => (tab = 'write')}>Write</button>
				<button
					type="submit"
					role="tab"
					formaction="?/preview"
					class:active={tab === 'preview'}
					aria-selected={tab === 'preview'}
				>Preview</button>
			</div>
			<div class="row">
				<button type="button" class="ghost" onclick={insertLink} title="Wrap selection in a [[wiki link]]">[[ link ]]</button>
				<button type="button" class="ghost" class:active={citeOpen} onclick={() => (citeOpen = !citeOpen)} title="Cite a source at the cursor">Cite</button>
			</div>
		</div>

		{#if citeOpen}
			<div class="cite-panel">
				<div class="fields">
					<div class="grow">
						<label for="cite-pick">Source</label>
						<select id="cite-pick" bind:value={citeId}>
							<option value="" disabled>Pick a source…</option>
							<option value={NEW_SOURCE}>+ New source for this page…</option>
							{#if pageSources.length}
								<optgroup label="This page">
									{#each pageSources as s (s.id)}<option value={s.id}>{s.title}</option>{/each}
								</optgroup>
							{/if}
							{#if library.length}
								<optgroup label="Library">
									{#each library as s (s.id)}<option value={s.id}>{s.title}</option>{/each}
								</optgroup>
							{/if}
						</select>
					</div>
					<div>
						<label for="cite-detail">Page / detail</label>
						<input
							id="cite-detail"
							bind:value={citeDetail}
							placeholder="p. 42"
							onkeydown={(e) => {
								if (e.key !== 'Enter') return;
								e.preventDefault(); // don't save the article
								if (citeId === NEW_SOURCE) citeForm?.requestSubmit();
								else insertCite(citeId);
							}}
						/>
					</div>
				</div>
				{#if citeId === NEW_SOURCE}
					<SourceFields prefix="cs_" idPrefix="cs" form="cite-src" />
					<button type="submit" form="cite-src" class="primary" disabled={citing}>{citing ? 'Saving…' : 'Create source & insert citation'}</button>
				{:else}
					<button type="button" class="primary" disabled={!citeId} onclick={() => insertCite(citeId)}>Insert citation</button>
				{/if}
				{#if citeError}<p class="notice error small">{citeError}</p>{/if}
				<p class="hint">Inserts <code>[cite:…]</code> at the cursor. Readers see a numbered footnote that links to the page's source list.</p>
			</div>
		{/if}

		<textarea bind:this={ta} name="body" bind:value={body} rows="22" hidden={tab !== 'write'} placeholder="Write in Markdown. Link other pages with [[slug]] or [[slug|label]]."></textarea>
		{#if tab === 'preview'}
			<div class="card prose preview">{@html preview || '<p class="muted">Nothing to preview.</p>'}</div>
		{/if}

		<p class="hint">
			Markdown with <code>[[slug]]</code> wiki links (red if the page doesn't exist yet) and <code>[cite:…]</code> citations from the Cite button.
			Keep dated claims in <a href="/e/{data.entity.slug}/facts">structured facts</a> too, so they show on the map and timeline.
		</p>

		<div class="fields">
			<div>
				<label for="status">Article status</label>
				<select id="status" name="status" bind:value={status}>
					{#each statuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}
				</select>
			</div>
			<div style="grid-column: span 2">
				<label for="summary">Edit summary</label>
				<input id="summary" name="summary" placeholder="What changed and why?" />
			</div>
		</div>
		{#if isMod}
			<input type="hidden" name="locked" value="off" />
			<label class="row"><input type="checkbox" name="locked" checked={data.article?.locked} /> Lock article (moderators only can edit)</label>
		{/if}

		<div class="row">
			<button class="primary">Save revision</button>
			<a class="btn ghost" href="/e/{data.entity.slug}">Cancel</a>
		</div>
	</form>

	<!-- The Cite panel's "new source" fields submit here (form="cite-src"); the article text stays as typed -->
	<form
		id="cite-src"
		method="post"
		action="?/addSource"
		hidden
		bind:this={citeForm}
		use:enhance={() => {
			citing = true;
			citeError = null;
			return async ({ result }) => {
				citing = false;
				if (result.type === 'success' && result.data?.newSource) {
					const src = result.data.newSource as SourceOption;
					added = [...added, src];
					citeId = src.id;
					await insertCite(src.id);
					citeForm?.reset();
				} else if (result.type === 'failure') citeError = String(result.data?.sourceError ?? 'Could not create the source.');
				else if (result.type === 'error') citeError = result.error?.message ?? 'Could not create the source.';
			};
		}}
	></form>
</div>

<style>
	.tabs button {
		border-radius: var(--radius) var(--radius) 0 0;
		border-bottom: 0;
	}
	.tabs button.active {
		background: var(--rust);
		border-color: var(--rust);
		color: white;
	}
	.cite-panel {
		display: grid;
		gap: 8px;
		padding: 10px 12px;
		background: var(--bg-2);
		border: 1px dashed var(--line-2);
		border-radius: var(--radius);
	}
	.cite-panel .fields {
		grid-template-columns: 2fr 1fr;
	}
	.cite-panel .primary {
		justify-self: start;
	}
	button.ghost.active {
		border-color: var(--rust);
		color: var(--rust-2);
	}
	textarea {
		font-family: var(--mono);
		font-size: 0.88rem;
		min-height: 420px;
	}
	.preview {
		min-height: 420px;
	}
</style>
