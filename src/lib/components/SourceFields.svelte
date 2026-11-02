<script lang="ts">
	import { SOURCE_KINDS } from '$lib/sources';

	/** The few fields needed to cite something new; full details can be added on the source's page later. */
	let {
		prefix = 'ns_',
		idPrefix = 'ns',
		form = undefined
	}: {
		/** form field name prefix (server: sourceFromForm(fd, prefix)) */
		prefix?: string;
		idPrefix?: string;
		/** id of the <form> these inputs belong to, when they sit outside it */
		form?: string;
	} = $props();
</script>

<div class="source-fields">
	<div class="fields">
		<div class="wide">
			<label for="{idPrefix}-title">Source title</label>
			<input id="{idPrefix}-title" name="{prefix}title" {form} required placeholder="Gary Post-Tribune, 12 May 1926" />
		</div>
		<div>
			<label for="{idPrefix}-kind">Kind</label>
			<select id="{idPrefix}-kind" name="{prefix}kind" {form}>
				{#each SOURCE_KINDS as k (k)}<option value={k} selected={k === 'newspaper'}>{k.replace('_', ' ')}</option>{/each}
			</select>
		</div>
		<div>
			<label for="{idPrefix}-pub">Published</label>
			<input id="{idPrefix}-pub" name="{prefix}published_on" {form} placeholder="1926 · May 1926" />
		</div>
		<div>
			<label for="{idPrefix}-author">Author</label>
			<input id="{idPrefix}-author" name="{prefix}author" {form} />
		</div>
		<div>
			<label for="{idPrefix}-publisher">Publisher / archive</label>
			<input id="{idPrefix}-publisher" name="{prefix}publisher" {form} />
		</div>
		<div class="wide">
			<label for="{idPrefix}-url">URL</label>
			<input id="{idPrefix}-url" name="{prefix}url" {form} type="url" placeholder="https://…" />
		</div>
	</div>
	<p class="hint">Saved with this page only. Use <em>Add to library</em> on the source's page to share it with other pages.</p>
</div>

<style>
	.source-fields {
		padding: 8px 10px;
		border-left: 3px solid var(--amber);
		background: var(--bg);
		border-radius: var(--radius);
	}
	.fields {
		grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
	}
	.wide {
		grid-column: 1 / -1;
	}
	.hint {
		margin: 6px 0 0;
	}
</style>
