<script lang="ts">
	import { toFuzzyInput } from '$lib/time';
	import { CONFIDENCES, PRECISIONS, type TemporalFact } from '$lib/types';

	let {
		values = null,
		sources = [],
		fromLabel = 'From',
		toLabel = 'Until',
		idPrefix = 'tf'
	}: {
		values?: Partial<TemporalFact> | null;
		sources?: { id: string; title: string }[];
		fromLabel?: string;
		toLabel?: string;
		idPrefix?: string;
	} = $props();

	const v = $derived(values ?? {});
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
		<div>
			<label for="{idPrefix}-src">Source</label>
			<select id="{idPrefix}-src" name="source_id">
				<option value="">(uncited)</option>
				{#each sources as s (s.id)}<option value={s.id} selected={v.source_id === s.id}>{s.title}</option>{/each}
			</select>
		</div>
		<div>
			<label for="{idPrefix}-srcd">Page / detail</label>
			<input id="{idPrefix}-srcd" name="source_detail" placeholder="p. 42, frame 7…" value={v.source_detail ?? ''} />
		</div>
		<div>
			<label for="{idPrefix}-note">Note</label>
			<input id="{idPrefix}-note" name="note" value={v.note ?? ''} />
		</div>
	</div>
</div>

<style>
	.temporal {
		padding: 10px 12px;
		background: var(--bg-2);
		border: 1px dashed var(--line-2);
		border-radius: var(--radius);
		margin: 8px 0;
	}
	.temporal .fields + .fields {
		margin-top: 8px;
	}
	.fields {
		grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
	}
</style>
