<script lang="ts">
	import { enhance } from '$app/forms';

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
			<button type="button" class="ghost" onclick={insertLink} title="Wrap selection in a [[wiki link]]">[[ link ]]</button>
		</div>

		<textarea bind:this={ta} name="body" bind:value={body} rows="22" hidden={tab !== 'write'} placeholder="Write in Markdown. Link other pages with [[slug]] or [[slug|label]]."></textarea>
		{#if tab === 'preview'}
			<div class="card prose preview">{@html preview || '<p class="muted">Nothing to preview.</p>'}</div>
		{/if}

		<p class="hint">
			Markdown with <code>[[slug]]</code> wiki links (red if the page doesn't exist yet).
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
	textarea {
		font-family: var(--mono);
		font-size: 0.88rem;
		min-height: 420px;
	}
	.preview {
		min-height: 420px;
	}
</style>
