<script lang="ts">
	import { enhance } from '$app/forms';
	import { VOCABS, type Field } from '$lib/vocabSchema';

	let { data, form } = $props();
	const def = $derived(VOCABS.find((v) => v.table === data.table)!);
	const show = (row: Record<string, unknown>, f: Field) => {
		const v = row[f.name];
		return Array.isArray(v) ? v.join(', ') : (v ?? '');
	};
</script>

<svelte:head><title>Vocabulary · Admin</title></svelte:head>

<h1>Vocabulary</h1>
<p class="muted" style="max-width: 75ch">
	The words the wiki uses, all editable for your region: what a page can be, condition names and colours, relationship
	types, event types, attributes and their units, article statuses and tag facets. Changes apply immediately.
</p>

<nav class="row tabs">
	{#each VOCABS as v (v.table)}
		<a class="btn" class:primary={v.table === data.table} href="?t={v.table}">{v.title}</a>
	{/each}
</nav>

{#if form?.error}<p class="notice error">{form.error}</p>{/if}
{#if form?.ok}<p class="notice ok">{form.ok}</p>{/if}

<p class="hint">{def.help}</p>

{#snippet input(f: Field, value: unknown, id: string)}
	{#if f.type === 'bool'}
		<input type="checkbox" name={f.name} checked={!!value} aria-label={f.label} />
	{:else if f.type === 'color'}
		<input type="color" name={f.name} value={(value as string) || '#c2562b'} aria-label={f.label} />
	{:else if f.type === 'select'}
		<select name={f.name} aria-label={f.label}>
			{#each f.options ?? [] as o (o)}<option value={o} selected={(value ?? '') === o}>{o || '—'}</option>{/each}
		</select>
	{:else}
		<input
			id="{id}-{f.name}"
			name={f.name}
			type={f.type === 'number' ? 'number' : 'text'}
			value={value as string}
			placeholder={f.type === 'list' ? 'any' : ''}
			aria-label={f.label}
		/>
	{/if}
{/snippet}

<div class="grid" style:--cols={def.fields.length}>
	<div class="head">
		<span>id</span>
		{#each def.fields as f (f.name)}<span class:wide={f.wide}>{f.label}</span>{/each}
		<span></span>
	</div>
	{#each data.rows as row (row.id)}
		<form method="post" action="?/save" class="vrow" use:enhance={() => async ({ update }) => update({ reset: false })}>
			<input type="hidden" name="table" value={def.table} />
			<input type="hidden" name="id" value={row.id} />
			<code title={def.core.includes(row.id as string) ? 'Used by the application' : ''}>{row.id}{def.core.includes(row.id as string) ? ' •' : ''}</code>
			{#each def.fields as f (f.name)}
				<span class:wide={f.wide}>{@render input(f, f.type === 'list' ? show(row, f) : row[f.name], String(row.id))}</span>
			{/each}
			<span class="acts">
				<button title="Save">Save</button>
				{#if !def.core.includes(row.id as string)}
					<button class="danger" formaction="?/delete" title="Delete">✕</button>
				{/if}
			</span>
		</form>
	{/each}
	<form method="post" action="?/add" class="vrow add" use:enhance>
		<input type="hidden" name="table" value={def.table} />
		<input name="id" placeholder="new_id" aria-label="New id" />
		{#each def.fields as f (f.name)}
			<span class:wide={f.wide}>{@render input(f, f.type === 'number' ? 100 : f.type === 'select' ? f.options?.[0] : '', 'new')}</span>
		{/each}
		<span class="acts"><button class="primary">Add</button></span>
	</form>
</div>
<p class="hint">• marks entries the application relies on: rename their labels freely, but they can't be deleted.</p>

<style>
	.tabs {
		margin: 12px 0;
		flex-wrap: wrap;
	}
	.grid {
		overflow-x: auto;
	}
	.head,
	.vrow {
		display: grid;
		grid-template-columns: 140px repeat(var(--cols), minmax(90px, 1fr)) 110px;
		gap: 6px;
		align-items: center;
		padding: 5px 0;
		border-bottom: 1px solid var(--line);
		min-width: 1000px;
	}
	.head {
		font-size: 0.72rem;
		text-transform: uppercase;
		letter-spacing: 0.06em;
		color: var(--muted);
	}
	.wide {
		min-width: 200px;
	}
	.vrow input,
	.vrow select {
		padding: 4px 6px;
		font-size: 0.82rem;
	}
	.vrow input[type='color'] {
		height: 30px;
		padding: 2px;
	}
	.vrow input[type='checkbox'] {
		width: 18px;
		height: 18px;
	}
	code {
		font-size: 0.78rem;
		word-break: break-all;
	}
	.acts {
		display: flex;
		gap: 4px;
	}
	.acts button {
		padding: 4px 10px;
		font-size: 0.8rem;
	}
	.add {
		background: rgba(127, 174, 106, 0.06);
	}
</style>
