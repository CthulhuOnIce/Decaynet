<script lang="ts">
	import type { EntityTag } from '$lib/types';
	import { formatRange } from '$lib/time';

	let { tags, showImplied = true }: { tags: EntityTag[]; showImplied?: boolean } = $props();
	const shown = $derived(
		[...tags]
			.filter((t) => showImplied || !t.implied)
			.sort((a, b) => a.facet_label.localeCompare(b.facet_label) || a.path.localeCompare(b.path))
	);
</script>

{#if shown.length}
	<ul class="chips">
		{#each shown as t (t.tag_id)}
			{@const when = formatRange(t.valid_from, t.valid_from_precision, t.valid_to, t.valid_to_precision)}
			<li>
				<a
					href="/tags/{t.slug}"
					class="chip"
					class:implied={t.implied}
					style:--c={t.color}
					title="{t.facet_label}: {t.path}{t.implied ? ' (implied by a sub-trait)' : ''}{when ? ` · ${when}` : ''}"
				>
					{t.label}{#if when && !t.implied}<span class="when">{when}</span>{/if}
				</a>
			</li>
		{/each}
	</ul>
{/if}

<style>
	.chips {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-wrap: wrap;
		gap: 5px;
	}
	.chip {
		display: inline-flex;
		align-items: baseline;
		gap: 6px;
		font-size: 0.78rem;
		padding: 2px 9px;
		border-radius: 4px;
		color: var(--ink);
		background: color-mix(in srgb, var(--c) 22%, transparent);
		border: 1px solid color-mix(in srgb, var(--c) 55%, transparent);
	}
	.chip:hover {
		text-decoration: none;
		border-color: var(--c);
	}
	.chip.implied {
		background: transparent;
		border-style: dashed;
		color: var(--ink-2);
	}
	.when {
		font-family: var(--mono);
		font-size: 0.68rem;
		color: var(--muted);
	}
</style>
