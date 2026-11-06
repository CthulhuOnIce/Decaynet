<script lang="ts">
	import { onMount } from 'svelte';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import { MODES, type CellFact, type Column, type GridRow, type RecordsContext, type WriteMode } from '$lib/records';
	import { parseFuzzyDate, toFuzzyInput } from '$lib/time';
	import type { LifecycleStatus, TagRow } from '$lib/types';

	export type EditorSubmit =
		| { kind: 'fact'; op: 'set' | 'add' | 'remove'; value: unknown; mode: WriteMode; to: string | null; to_p: string }
		| { kind: 'page'; patch: Record<string, unknown> };

	let {
		col,
		row,
		context,
		statuses,
		tags,
		count = 1,
		initial = '',
		onsubmit,
		oncancel
	}: {
		col: Column;
		row: GridRow;
		context: RecordsContext;
		statuses: LifecycleStatus[];
		tags: TagRow[];
		/** how many rows it applies to (the selection, when this row is in it) */
		count?: number;
		/** a key typed on the cell starts the editor with it */
		initial?: string;
		onsubmit: (s: EditorSubmit) => void;
		oncancel: () => void;
	} = $props();

	const facts: CellFact[] = $derived(row.cells[col.id] ?? []);
	const first = $derived(facts[0]);
	const year = $derived(context.at ? context.at.slice(0, 4) : '');

	// svelte-ignore state_referenced_locally
	let mode = $state<WriteMode>(context.mode);
	// svelte-ignore state_referenced_locally
	let toText = $state(context.to ? toFuzzyInput(context.to, context.to_p as never) : '');
	// svelte-ignore state_referenced_locally
	let text = $state(
		initial ||
			(col.id === 'summary'
				? (row.summary ?? '')
				: col.id === 'name'
					? (facts[0]?.label ?? row.name_then)
					: facts[0]
						? typeof facts[0].v === 'string' || typeof facts[0].v === 'number'
							? String(facts[0].v)
							: facts[0].label
						: '')
	);
	// svelte-ignore state_referenced_locally
	let status = $state((first?.v as string) ?? '');
	// address
	const addr = $derived((first?.v ?? {}) as { street_id?: string; house_number?: string; unit?: string });
	// svelte-ignore state_referenced_locally
	let street = $state<{ id: string; name: string } | null>(
		addr.street_id
			? { id: addr.street_id, name: (first?.label ?? '').replace(addr.house_number ? `${addr.house_number} ` : '', '').replace(/\s+#.*$/, '').trim() }
			: null
	);
	// svelte-ignore state_referenced_locally
	let number = $state(initial || addr.house_number || '');
	// svelte-ignore state_referenced_locally
	let unit = $state(addr.unit ?? '');
	// several at once
	let addTag = $state('');
	let replace = $state(false);
	// lifespan
	// svelte-ignore state_referenced_locally
	let fromText = $state(row.from ? toFuzzyInput(row.from, row.from_p as never) : '');
	// svelte-ignore state_referenced_locally
	let untilText = $state(row.to ? toFuzzyInput(row.to, row.to_p as never) : '');
	let problem = $state('');

	let box: HTMLDivElement;
	onMount(() => {
		const el = box.querySelector<HTMLElement>('input:not([type=checkbox]), select, textarea');
		el?.focus();
		if (el instanceof HTMLInputElement && !initial) el.select();
	});

	function fact(op: 'set' | 'add' | 'remove', value: unknown) {
		const to = mode === 'only' ? parseFuzzyDate(toText) : null;
		if (mode === 'only' && !to) {
			problem = '“Only” needs an end year.';
			return;
		}
		onsubmit({ kind: 'fact', op, value, mode, to: to?.date ?? null, to_p: to?.precision ?? 'year' });
	}

	function save() {
		problem = '';
		if (col.type === 'page') {
			if (col.id === 'summary') return onsubmit({ kind: 'page', patch: { summary: text } });
			const f = fromText.trim() ? parseFuzzyDate(fromText) : null;
			const u = untilText.trim() ? parseFuzzyDate(untilText) : null;
			if ((fromText.trim() && !f) || (untilText.trim() && !u)) {
				problem = 'Dates look like 1925, the 1920s or May 1925.';
				return;
			}
			return onsubmit({
				kind: 'page',
				patch: { exists_from: f?.date ?? null, exists_from_precision: f?.precision ?? 'year', exists_to: u?.date ?? null, exists_to_precision: u?.precision ?? 'year' }
			});
		}
		if (col.input === 'status') return status ? fact('set', status) : fact('remove', null);
		if (col.input === 'address') {
			if (!number.trim() && !street) return fact('remove', null);
			// a whole address typed into the number box ("512 Broadway") is looked up
			if (!street && /\D/.test(number.trim().replace(/^\d+[a-z]?$/i, ''))) return fact('set', { text: number.trim(), unit: unit.trim() || undefined });
			return fact('set', { street_id: street?.id, house_number: number.trim() || undefined, unit: unit.trim() || undefined });
		}
		if (col.input === 'tag') return addTag ? fact('add', addTag) : oncancel();
		if (!text.trim()) return fact('remove', null);
		fact('set', text.trim());
	}

	function key(e: KeyboardEvent) {
		if (e.key === 'Escape') {
			e.preventDefault();
			e.stopPropagation();
			oncancel();
		} else if (e.key === 'Enter' && !(e.target instanceof HTMLTextAreaElement && !e.ctrlKey && !e.metaKey) && !(e.target as HTMLElement).closest('.picker')) {
			e.preventDefault();
			e.stopPropagation();
			save();
		}
	}

	const whenLabel = $derived(
		col.type === 'page'
			? 'the page itself (no dates)'
			: mode === 'correct'
				? `fix what's recorded in ${year}`
				: mode === 'only'
					? `only ${year}–${toText || '?'}`
					: mode === 'starting'
						? `starting ${year}`
						: `seen in ${year}`
	);
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="editor" bind:this={box} onkeydown={key} role="dialog" aria-label="Edit {col.label} for {row.name}" tabindex="-1">
	<div class="head">
		<strong>{col.label}</strong>
		<span class="muted small">· {row.name_then}{count > 1 ? ` and ${count - 1} more selected` : ''}</span>
	</div>

	{#if col.input === 'text' || col.input === 'number'}
		{#if col.id === 'summary'}
			<textarea rows="3" bind:value={text}></textarea>
		{:else}
			<div class="row nowrap">
				<input type="text" inputmode={col.input === 'number' ? 'decimal' : undefined} bind:value={text} placeholder={col.input === 'number' ? '0' : ''} />
				{#if col.unit}<span class="muted small">{col.unit}</span>{/if}
			</div>
		{/if}
	{:else if col.input === 'status'}
		<select bind:value={status}>
			<option value="">— none then —</option>
			{#each statuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}
		</select>
	{:else if col.input === 'address'}
		<div class="addr">
			<input class="num" type="text" bind:value={number} placeholder={street ? '512' : '512 Broadway'} aria-label="House number" />
			<div class="street">
				<EntityPicker name="street" kinds={['street']} value={street} placeholder="Street…" onpick={(p) => (street = p ? { id: p.id, name: p.name } : null)} />
			</div>
			<input class="unit" type="text" bind:value={unit} placeholder="Unit" aria-label="Unit" />
		</div>
	{:else if col.input === 'tag' || col.input === 'entity'}
		{#if facts.length}
			<ul class="chips">
				{#each facts as f (f.id)}
					<li>
						<span>{f.label} <span class="muted small">{f.span}</span></span>
						<button type="button" class="x" title="Not {mode === 'starting' ? `after ${year}` : `in ${year}`}" onclick={() => fact('remove', f.v)}>×</button>
					</li>
				{/each}
			</ul>
		{/if}
		{#if col.input === 'tag'}
			<div class="row nowrap">
				<select class="grow" bind:value={addTag} aria-label="Add a tag">
					<option value="">Add a tag…</option>
					{#each tags as tg (tg.id)}<option value={tg.id}>{tg.path}</option>{/each}
				</select>
				<button type="button" class="primary" disabled={!addTag} onclick={() => fact('add', addTag)}>Add</button>
			</div>
		{:else}
			<div class="picker">
				<EntityPicker name="other" kinds={col.kinds ?? null} placeholder="Add a page…" onpick={(p) => p && fact(replace ? 'set' : 'add', p.id)} />
			</div>
			<label class="check small"><input type="checkbox" bind:checked={replace} /> Replaces the others (they left)</label>
		{/if}
	{:else if col.input === 'span'}
		<div class="addr">
			<input type="text" bind:value={fromText} placeholder="From (1925, 1920s…)" aria-label="From" />
			<input type="text" bind:value={untilText} placeholder="Until" aria-label="Until" />
		</div>
	{/if}

	{#if col.type === 'fact'}
		<div class="modes" role="radiogroup" aria-label="How it lands in time">
			{#each MODES as m (m.id)}
				<button type="button" class="pill" class:on={mode === m.id} role="radio" aria-checked={mode === m.id} title={m.hint} onclick={() => (mode = m.id)}>{m.label}</button>
			{/each}
			{#if mode === 'only'}<input class="to" type="text" bind:value={toText} placeholder="until" aria-label="Until" />{/if}
		</div>
	{/if}
	{#if problem}<p class="notice error small">{problem}</p>{/if}
	<div class="spread foot">
		<span class="muted small">{whenLabel}{col.type === 'fact' && mode !== 'correct' ? ' · cited' : ''}</span>
		<span class="row">
			<button type="button" class="ghost" onclick={oncancel}>Cancel</button>
			{#if !(col.input === 'tag' || col.input === 'entity')}
				<button type="button" class="primary" onclick={save}>{count > 1 ? `Preview ${count}` : 'Save'}</button>
			{/if}
		</span>
	</div>
</div>

<style>
	.editor {
		position: absolute;
		z-index: 30;
		min-width: 320px;
		max-width: min(460px, calc(100vw - 32px));
		background: var(--panel);
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45);
		padding: 10px 12px;
		display: grid;
		gap: 8px;
	}
	.head {
		display: flex;
		gap: 6px;
		align-items: baseline;
		flex-wrap: wrap;
	}
	.nowrap {
		flex-wrap: nowrap;
	}
	.grow {
		flex: 1;
	}
	.addr {
		display: flex;
		gap: 6px;
		flex-wrap: wrap;
	}
	.addr .num {
		width: 9ch;
		flex: 0 0 auto;
	}
	.addr .num:only-child {
		width: 100%;
	}
	.addr .street {
		flex: 1 1 160px;
	}
	.addr .unit {
		width: 8ch;
	}
	.chips {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
	}
	.chips li {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		border: 1px solid var(--line-2);
		border-radius: 999px;
		padding: 2px 4px 2px 9px;
		font-size: 0.85rem;
	}
	.x {
		padding: 0 6px;
		border: 0;
		background: transparent;
		color: var(--muted);
	}
	.x:hover {
		color: var(--danger);
	}
	.modes {
		display: flex;
		gap: 4px;
		flex-wrap: wrap;
		align-items: center;
	}
	.pill {
		padding: 3px 9px;
		font-size: 0.8rem;
		border-radius: 999px;
		background: transparent;
	}
	.pill.on {
		background: var(--rust);
		border-color: var(--rust);
		color: #fff;
	}
	.to {
		width: 9ch;
		padding: 3px 6px;
	}
	.check {
		display: flex;
		gap: 6px;
		align-items: center;
		margin: 0;
	}
	.foot {
		margin-top: 2px;
	}
</style>
