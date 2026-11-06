<script lang="ts">
	import { enhance } from '$app/forms';
	import { TABLE_LABELS } from '$lib/records';
	import { formatFuzzy, formatRange } from '$lib/time';
	import LogTable from '../../LogTable.svelte';
	import RecordsNav from '../../RecordsNav.svelte';

	let { data, form } = $props();
	const s = $derived(data.set);
	const when = (d: string) => new Date(d).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
	const pages = $derived(Math.max(1, Math.ceil(data.total / data.per)));

</script>

<svelte:head><title>{s.title || 'Change set'} · Records · Admin</title></svelte:head>

<RecordsNav />

<div class="spread">
	<form method="post" action="?/rename" use:enhance={() => async ({ update }) => update({ reset: false })} class="title">
		<input name="title" value={s.title} aria-label="Name of this change set" placeholder="Untitled set" />
		<button class="ghost">Rename</button>
	</form>
	<span class="row">
		<a class="btn ghost" href="/admin/records/sets">All sets</a>
		<a class="btn ghost" href="/admin/records">Back to Records</a>
	</span>
</div>
<p class="muted small">
	Working in {s.context?.at ? (s.context.to ? formatRange(s.context.at, s.context.at_p as never, s.context.to, (s.context.to_p ?? 'year') as never) : formatFuzzy(s.context.at, s.context.at_p as never)) : '—'},
	{s.context?.mode ?? 'seen'}{s.context?.source_id ? `, citing ${data.sources[s.context.source_id] ?? 'a source'}` : ''} ·
	started {when(s.created_at)} · last change {when(s.updated_at)}
	{#if s.undone_at}· <strong>undone {when(s.undone_at)}</strong>{/if}
</p>

{#if form && 'error' in form && form.error}<p class="notice error">{form.error}</p>{/if}
{#if form && 'undone' in form}<p class="notice ok">Undid {form.undone} changes.</p>{/if}

{#if !s.undone_at && data.undo}
	<div class="undo card">
		{#if data.undo.conflicts.length}
			<p><strong>Can't undo as a whole:</strong> since this set, these were changed again elsewhere. Undo or adjust those first.</p>
			<ul class="small">
				{#each data.undo.conflicts.slice(0, 20) as c, i (i)}<li>{c.name ?? 'a page'} · {TABLE_LABELS[c.table] ?? c.table} · {when(c.at)}</li>{/each}
			</ul>
		{:else}
			<form method="post" action="?/undo" use:enhance={({ cancel }) => { if (!confirm(`Undo all ${data.total} changes in this set?`)) cancel(); }}>
				<span>{data.total} change{data.total === 1 ? '' : 's'} in this set. Undoing puts every page back as it was before it, deleted pages included.</span>
				<button class="danger-btn">Undo the whole set</button>
			</form>
		{/if}
	</div>
{/if}

{#if data.rows.length}
	<LogTable rows={data.rows} names={data.names} sources={data.sources} tags={data.tags} />
	{#if pages > 1}
		<nav class="row small">
			{#if data.pageNo > 1}<a href="?page={data.pageNo - 1}">‹ Newer</a>{/if}
			<span>Page {data.pageNo} of {pages}</span>
			{#if data.pageNo < pages}<a href="?page={data.pageNo + 1}">Older ›</a>{/if}
		</nav>
	{/if}
{:else}
	<p class="muted">Nothing in this set yet.</p>
{/if}

<style>
	.title {
		display: flex;
		gap: 8px;
		align-items: center;
		flex: 1 1 300px;
	}
	.title input {
		font-size: 1.3rem;
		font-family: var(--serif);
		background: transparent;
		border-color: transparent;
	}
	.title input:hover,
	.title input:focus {
		border-color: var(--line-2);
	}
	.undo {
		margin: 12px 0;
	}
	.undo form {
		display: flex;
		gap: 12px;
		align-items: center;
		flex-wrap: wrap;
	}
	.danger-btn {
		color: var(--danger);
		border-color: var(--danger);
		background: transparent;
	}
</style>
