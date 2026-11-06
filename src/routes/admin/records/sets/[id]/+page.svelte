<script lang="ts">
	import { enhance } from '$app/forms';
	import { FIELD_LABELS, TABLE_LABELS, changedFields, type LogRow } from '$lib/records';
	import { formatFuzzy, formatRange } from '$lib/time';

	let { data, form } = $props();
	const s = $derived(data.set);
	const when = (d: string) => new Date(d).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
	const pages = $derived(Math.max(1, Math.ceil(data.total / data.per)));

	/** A value as people read it: page and source names, dates with their precision. */
	function show(k: string, v: unknown, d: Record<string, unknown> | null): string {
		if (v === null || v === undefined || v === '') return '—';
		if (['entity_id', 'subject_id', 'object_id', 'street_id'].includes(k)) return data.names[v as string]?.name ?? 'a deleted page';
		if (k === 'source_id') return data.sources[v as string] ?? 'a source';
		if (k === 'tag_id') return data.tags[v as string] ?? 'a tag';
		if ((k === 'valid_from' || k === 'valid_to' || k === 'exists_from' || k === 'exists_to') && typeof v === 'string')
			return formatFuzzy(v, ((d?.[`${k}_precision`] as string) ?? 'day') as never);
		if (typeof v === 'object') return JSON.stringify(v);
		return String(v);
	}

	/** What a row says, in a line: "vacant 1948–", "512 Broadway 1925–1930", "Kresge occupies …". */
	function gist(r: LogRow): string {
		const d = (r.new_data ?? r.old_data ?? {}) as Record<string, unknown>;
		const span = formatRange(d.valid_from as string, d.valid_from_precision as never, d.valid_to as string, d.valid_to_precision as never);
		const t = r.table_name;
		const what =
			t === 'entity_names' ? `“${d.name}”`
			: t === 'entity_states' ? String(d.status)
			: t === 'addresses' ? `${d.house_number ?? ''} ${show('street_id', d.street_id, d)}${d.unit ? ` #${d.unit}` : ''}`.trim()
			: t === 'entity_attributes' ? `${d.key}: ${typeof d.value === 'object' ? JSON.stringify(d.value) : d.value}`
			: t === 'entity_tags' ? show('tag_id', d.tag_id, d)
			: t === 'relations' ? `${show('subject_id', d.subject_id, d)} ${String(d.predicate).replace('_', ' ')} ${show('object_id', d.object_id, d)}`
			: t === 'entities' ? `${d.name} (${d.kind})`
			: t === 'entity_geometries' ? String(d.role ?? 'shape')
			: '';
		return [what, span, d.source_id ? `· ${show('source_id', d.source_id, d)}` : ''].filter(Boolean).join(' ');
	}
	const page = (r: LogRow) => (r.entity_id ? data.names[r.entity_id] : null);
</script>

<svelte:head><title>{s.title || 'Change set'} · Records · Admin</title></svelte:head>

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
	<table class="log">
		<thead><tr><th>When</th><th>Page</th><th>What</th><th>Change</th></tr></thead>
		<tbody>
			{#each data.rows as r (r.id)}
				{@const p = page(r)}
				<tr>
					<td class="small nowrap">{new Date(r.created_at).toLocaleTimeString(undefined, { timeStyle: 'short' })}</td>
					<td>{#if p}<a href="/e/{p.slug}">{p.name}</a>{:else}<span class="muted">deleted page</span>{/if}</td>
					<td class="small"><span class="op {r.op.toLowerCase()}">{r.op === 'INSERT' ? 'added' : r.op === 'DELETE' ? 'removed' : 'changed'}</span> {TABLE_LABELS[r.table_name] ?? r.table_name}</td>
					<td class="small">
						{#if r.op === 'UPDATE'}
							{#each changedFields(r) as [k, a, b] (k)}
								<div><span class="muted">{FIELD_LABELS[k] ?? k.replace(/_/g, ' ')}:</span> <del>{show(k, a, r.old_data)}</del> → <ins>{show(k, b, r.new_data)}</ins></div>
							{/each}
							<div class="muted">{gist(r)}</div>
						{:else}
							{gist(r)}
						{/if}
					</td>
				</tr>
			{/each}
		</tbody>
	</table>
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
	.log td {
		vertical-align: top;
	}
	.nowrap {
		white-space: nowrap;
	}
	.op.insert {
		color: var(--moss);
	}
	.op.delete {
		color: var(--danger);
	}
	.op.update {
		color: var(--amber);
	}
	del {
		color: var(--muted);
	}
	ins {
		text-decoration: none;
		color: var(--ink);
	}
</style>
