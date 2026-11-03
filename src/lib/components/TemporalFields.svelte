<script lang="ts">
	import { untrack } from 'svelte';
	import { NEW_SOURCE, type SourceOption } from '$lib/sources';
	import { toFuzzyInput } from '$lib/time';
	import { CONFIDENCES, PRECISIONS, type TemporalFact } from '$lib/types';
	import SourceFields from './SourceFields.svelte';
	import SourcePicker from './SourcePicker.svelte';

	let {
		values = null,
		sources = [],
		fromLabel = 'From',
		toLabel = 'Until',
		idPrefix = 'tf',
		allowNew = true
	}: {
		values?: Partial<TemporalFact> | null;
		/** entity_id set = made for this page; null/absent = shared library */
		sources?: SourceOption[];
		fromLabel?: string;
		toLabel?: string;
		idPrefix?: string;
		/** offer "New source…" (the server must call resolveInlineSource) */
		allowNew?: boolean;
	} = $props();

	const v = $derived(values ?? {});
	// A fact can cite a source this list doesn't offer (another page's); the picker keeps it rather than silently uncite
	let picked = $state(untrack(() => values?.source_id ?? ''));
</script>

<div class="temporal">
	<div class="fields">
		<div>
			<label for="{idPrefix}-from">{fromLabel}</label>
			<input id="{idPrefix}-from" name="valid_from" placeholder="1926 · 1920s · c. 1926" value={toFuzzyInput(v.valid_from, v.valid_from_precision ?? 'year')} />
		</div>
		<div>
			<label for="{idPrefix}-fromp">precision</label>
			<select id="{idPrefix}-fromp" name="valid_from_precision">
				<option value="">auto</option>
				{#each PRECISIONS as p (p)}<option value={p} selected={values != null && v.valid_from_precision === p && !!v.valid_from}>{p}</option>{/each}
			</select>
		</div>
		<div>
			<label for="{idPrefix}-to">{toLabel}</label>
			<input id="{idPrefix}-to" name="valid_to" placeholder="blank = still true" value={toFuzzyInput(v.valid_to, v.valid_to_precision ?? 'year')} />
		</div>
		<div>
			<label for="{idPrefix}-top">precision</label>
			<select id="{idPrefix}-top" name="valid_to_precision">
				<option value="">auto</option>
				{#each PRECISIONS as p (p)}<option value={p} selected={values != null && v.valid_to_precision === p && !!v.valid_to}>{p}</option>{/each}
			</select>
		</div>
		<div>
			<label for="{idPrefix}-conf">Confidence</label>
			<select id="{idPrefix}-conf" name="confidence">
				{#each CONFIDENCES as c (c)}<option value={c} selected={(v.confidence ?? 'probable') === c}>{c}</option>{/each}
			</select>
		</div>
	</div>
	<div class="fields">
		<div class="source">
			<label for="{idPrefix}-src">Source</label>
			<SourcePicker id="{idPrefix}-src" name="source_id" {sources} {allowNew} bind:value={picked} resetValue={values?.source_id ?? ''} />
		</div>
		<div>
			<label for="{idPrefix}-srcd">Page / detail</label>
			<input id="{idPrefix}-srcd" name="source_detail" placeholder="p. 42, frame 7…" value={v.source_detail ?? ''} />
		</div>
		<div>
			<label for="{idPrefix}-note" title="For editors; not shown on the timeline">Internal note</label>
			<input id="{idPrefix}-note" name="note" value={v.note ?? ''} />
		</div>
	</div>
	{#if picked === NEW_SOURCE}
		<div class="new-source"><SourceFields idPrefix="{idPrefix}-ns" /></div>
	{/if}
</div>

<style>
	.temporal {
		padding: 10px 12px;
		background: var(--bg-2);
		border: 1px dashed var(--line-2);
		border-radius: var(--radius);
		margin: 8px 0;
	}
	.temporal .fields + .fields,
	.new-source {
		margin-top: 8px;
	}
	.fields {
		grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
	}
	.fields .source {
		grid-column: span 2;
	}
</style>
