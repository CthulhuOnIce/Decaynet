<script lang="ts">
	import { untrack } from 'svelte';
	import { goto, invalidateAll } from '$app/navigation';
	import { page } from '$app/state';
	import SourcePicker from '$lib/components/SourcePicker.svelte';
	import { FACT_TABLES, type FactRow } from '$lib/records';
	import { parseFuzzyDate, toFuzzyInput } from '$lib/time';
	import { CONFIDENCES, type Vocabulary } from '$lib/types';
	import RecordsNav from '../RecordsNav.svelte';

	let { data } = $props();
	const vocab = $derived(page.data.vocab as Vocabulary);
	const q = $derived(data.q);
	const rows = $derived(data.rows as FactRow[]);
	const pages = $derived(Math.max(1, Math.ceil(data.total / data.per)));
	const ctx = $derived((data.current?.context ?? {}) as { source_id?: string; source_detail?: string; at?: string });
	const ctxSource = $derived(data.sources.find((s) => s.id === ctx.source_id)?.title ?? null);

	function nav(change: (u: URLSearchParams) => void, keepPage = false) {
		const u = new URLSearchParams(page.url.search);
		change(u);
		if (!keepPage) u.delete('page');
		goto(`?${u}`, { keepFocus: true, noScroll: true });
	}
	const setParam = (k: string, v: string | null) => nav((u) => (v ? u.set(k, v) : u.delete(k)));
	let text = $state(untrack(() => data.q.text ?? ''));

	// ---- selection
	let sel = $state<Set<string>>(new Set());
	let last = $state<number | null>(null);
	$effect(() => {
		void q.table;
		untrack(() => (sel = new Set()));
	});
	function tick(i: number, e: MouseEvent) {
		const next = new Set(sel);
		const on = !sel.has(rows[i].id);
		if (e.shiftKey && last !== null) for (let k = Math.min(last, i); k <= Math.max(last, i); k++) on ? next.add(rows[k].id) : next.delete(rows[k].id);
		else on ? next.add(rows[i].id) : next.delete(rows[i].id);
		sel = next;
		last = i;
	}
	const allOn = $derived(rows.length > 0 && rows.every((r) => sel.has(r.id)));

	// ---- talking to the server
	let toast = $state<{ text: string; kind: 'ok' | 'error' | 'info' } | null>(null);
	let undo = $state<{ after: number; label: string }[]>([]);
	async function api(body: unknown) {
		const r = await fetch('/admin/records/api', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
		const j = await r.json().catch(() => ({ message: r.statusText }));
		if (!r.ok) throw new Error(j.message ?? 'Something went wrong');
		return j;
	}
	async function act(label: string, body: Record<string, unknown>) {
		if (!data.current) return (toast = { text: 'Open a change set first (Records › Pages, the bar at the top).', kind: 'error' });
		try {
			const r = (await api(body)) as { changed?: number; deleted?: number; after: number };
			undo = [...undo, { after: r.after, label }];
			toast = { text: `${label}: ${r.changed ?? r.deleted ?? 0} record${(r.changed ?? r.deleted) === 1 ? '' : 's'}.`, kind: 'ok' };
			await invalidateAll();
		} catch (e) {
			toast = { text: (e as Error).message, kind: 'error' };
		}
	}
	async function undoLast() {
		const l = undo.at(-1);
		if (!l) return;
		try {
			const r = (await api({ op: 'undoLast', after: l.after })) as { undone: boolean };
			if (!r.undone) return (toast = { text: `Can't undo “${l.label}”: changed since.`, kind: 'error' });
			undo = undo.slice(0, -1);
			toast = { text: `Undid: ${l.label}`, kind: 'info' };
			await invalidateAll();
		} catch (e) {
			toast = { text: (e as Error).message, kind: 'error' };
		}
	}
	const cite = () => act(`Cited ${ctxSource}`, { op: 'factUpdate', table: q.table, ids: [...sel], patch: { source_id: ctx.source_id, source_detail: ctx.source_detail ?? null } });
	let conf = $state('');
	const setConf = () => conf && act(`Confidence: ${conf}`, { op: 'factUpdate', table: q.table, ids: [...sel], patch: { confidence: conf } });
	let confirmDelete = $state(false);
	async function del() {
		confirmDelete = false;
		await act('Deleted', { op: 'factDelete', table: q.table, ids: [...sel] });
		sel = new Set();
	}

	// ---- editing one record in place (a correction: no new history)
	let edit = $state<{ id: string; value: string; unit: string; from: string; to: string; conf: string; src: string; detail: string; note: string } | null>(null);
	function startEdit(r: FactRow) {
		const raw = r.raw as Record<string, unknown>;
		edit = {
			id: r.id,
			value: q.table === 'entity_names' ? String(raw.name ?? '') : q.table === 'entity_states' ? String(raw.status ?? '') : q.table === 'entity_attributes' ? String(raw.value ?? '') : q.table === 'addresses' ? String(raw.house_number ?? '') : '',
			unit: String(raw.unit ?? ''),
			from: r.f ? toFuzzyInput(r.f, r.fp as never) : '',
			to: r.t ? toFuzzyInput(r.t, r.tp as never) : '',
			conf: r.conf,
			src: r.src ?? '',
			detail: r.detail ?? '',
			note: r.note ?? ''
		};
	}
	const valueEditable = $derived(['entity_names', 'entity_states', 'entity_attributes', 'addresses'].includes(q.table));
	async function saveEdit(r: FactRow) {
		if (!edit) return;
		const e = edit;
		const f = e.from.trim() ? parseFuzzyDate(e.from) : null;
		const t = e.to.trim() ? parseFuzzyDate(e.to) : null;
		if ((e.from.trim() && !f) || (e.to.trim() && !t)) return (toast = { text: 'Dates look like 1925, the 1920s or May 1925.', kind: 'error' });
		const patch: Record<string, unknown> = {
			valid_from: f?.date ?? null,
			valid_from_precision: f?.precision ?? 'year',
			valid_to: t?.date ?? null,
			valid_to_precision: t?.precision ?? 'year',
			confidence: e.conf,
			source_id: e.src || null,
			source_detail: e.detail,
			note: e.note
		};
		if (q.table === 'entity_names') patch.name = e.value;
		if (q.table === 'entity_states') patch.status = e.value;
		if (q.table === 'addresses') Object.assign(patch, { house_number: e.value, unit: e.unit });
		if (q.table === 'entity_attributes') {
			const key = vocab.attributeKeys.find((k) => k.id === (r.raw as { key?: string }).key);
			patch.value = key?.value_type === 'number' && /^-?\d+(\.\d+)?$/.test(e.value.trim()) ? Number(e.value) : e.value;
		}
		edit = null;
		await act(`Corrected ${r.name}`, { op: 'factUpdate', table: q.table, ids: [r.id], patch });
	}
	function keys(e: KeyboardEvent) {
		if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z' && !(e.target as HTMLElement).closest('input, select, textarea')) {
			e.preventDefault();
			undoLast();
		}
	}
	function csv() {
		const list = sel.size ? rows.filter((r) => sel.has(r.id)) : rows;
		const esc = (v: string) => (/[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
		const out = [['Page', 'Kind', 'Value', 'From', 'Until', 'Confidence', 'Source', 'Where in it', 'Note'], ...list.map((r) => [r.name, r.kind, r.value, r.f ?? '', r.t ?? '', r.conf, r.src_title ?? '', r.detail ?? '', r.note ?? ''])];
		const a = document.createElement('a');
		a.href = URL.createObjectURL(new Blob([out.map((l) => l.map((v) => esc(String(v))).join(',')).join('\n')], { type: 'text/csv' }));
		a.download = `${q.table}.csv`;
		a.click();
	}
</script>

<svelte:head><title>Each record · Records · Admin</title></svelte:head>
<svelte:window onkeydown={keys} />

<RecordsNav />

<nav class="tables" aria-label="Which records">
	{#each FACT_TABLES as t (t.id)}
		<a href="?table={t.id}{q.ids.length ? `&ids=${q.ids.join(',')}` : ''}" class:on={q.table === t.id}>{t.label}</a>
	{/each}
</nav>

<section class="filters">
	<form onsubmit={(e) => (e.preventDefault(), setParam('text', text.trim() || null))}><input type="search" bind:value={text} placeholder="Value contains…" aria-label="Value contains" /></form>
	<select aria-label="Kind of page" value={q.kinds[0] ?? ''} onchange={(e) => setParam('kind', (e.currentTarget as HTMLSelectElement).value || null)}>
		<option value="">All kinds</option>
		{#each vocab.kinds as k (k.id)}<option value={k.id}>{k.label}</option>{/each}
	</select>
	{#if q.table === 'entity_attributes'}
		<select aria-label="Which fact" value={q.key ?? ''} onchange={(e) => setParam('key', (e.currentTarget as HTMLSelectElement).value || null)}>
			<option value="">Every fact</option>
			{#each vocab.attributeKeys as k (k.id)}<option value={k.id}>{k.label}</option>{/each}
		</select>
	{:else if q.table === 'relations'}
		<select aria-label="Which link" value={q.predicate ?? ''} onchange={(e) => setParam('predicate', (e.currentTarget as HTMLSelectElement).value || null)}>
			<option value="">Every link</option>
			{#each vocab.relationTypes as r (r.id)}<option value={r.id}>{r.label}</option>{/each}
		</select>
	{/if}
	<label class="inline small"><input type="checkbox" checked={q.uncited} onchange={(e) => setParam('uncited', (e.currentTarget as HTMLInputElement).checked ? '1' : null)} /> Uncited only</label>
	<select aria-label="Confidence" value={q.confidences[0] ?? ''} onchange={(e) => setParam('conf', (e.currentTarget as HTMLSelectElement).value || null)}>
		<option value="">Any confidence</option>
		{#each CONFIDENCES as c (c)}<option value={c}>{c}</option>{/each}
	</select>
	<label class="inline small">In force
		<input class="yr" value={q.from_year ?? ''} placeholder="from" onchange={(e) => setParam('from', (e.currentTarget as HTMLInputElement).value || null)} aria-label="From year" />
		–
		<input class="yr" value={q.to_year ?? ''} placeholder="to" onchange={(e) => setParam('to', (e.currentTarget as HTMLInputElement).value || null)} aria-label="To year" />
	</label>
	<span class="grow"></span>
	<label class="inline small">Sort
		<select value={q.sort} onchange={(e) => setParam('sort', (e.currentTarget as HTMLSelectElement).value)}>
			<option value="page">Page</option><option value="start">Oldest first</option><option value="updated">Recently changed</option>
		</select>
	</label>
</section>
{#if q.ids.length || q.set}
	<div class="chips">
		{#if q.ids.length}<button class="chip" onclick={() => setParam('ids', null)}>{q.ids.length} picked page{q.ids.length === 1 ? '' : 's'} ×</button>{/if}
		{#if q.set}<button class="chip" onclick={() => setParam('set', null)}>In one change set ×</button>{/if}
	</div>
{/if}

<div class="bulkbar" class:on={sel.size > 0}>
	{#if sel.size}
		<strong>{sel.size} selected</strong>
		<button class="ghost" onclick={cite} disabled={!ctxSource} title={ctxSource ? '' : 'Open a change set with a source first'}>Cite {ctxSource ?? 'the open source'}</button>
		<select bind:value={conf} aria-label="Set confidence"><option value="">Confidence…</option>{#each CONFIDENCES as c (c)}<option value={c}>{c}</option>{/each}</select>
		<button class="ghost" onclick={setConf} disabled={!conf}>Set</button>
		<button class="ghost danger-text" onclick={() => (confirmDelete = true)}>Delete…</button>
		<button class="ghost" onclick={() => (sel = new Set())}>Untick</button>
	{:else}
		<span class="muted small">{data.total} record{data.total === 1 ? '' : 's'} · double-click one to correct it in place · tick (Shift for a run) to cite or clean up several{data.current ? '' : ' · open a change set to edit'}</span>
	{/if}
	<span class="grow"></span>
	{#if undo.length}<button class="ghost" onclick={undoLast} title="Ctrl+Z">Undo “{undo.at(-1)?.label}”</button>{/if}
	<button class="ghost" onclick={csv} disabled={!rows.length}>CSV</button>
</div>

<div class="wrap">
	<table>
		<thead>
			<tr>
				<th class="tick"><input type="checkbox" checked={allOn} onchange={() => (sel = allOn ? new Set() : new Set(rows.map((r) => r.id)))} aria-label="Select this page" /></th>
				<th>Page</th>
				<th>Record</th>
				<th>When</th>
				<th>Confidence</th>
				<th>Source</th>
				<th>Where in it</th>
				<th>Note</th>
			</tr>
		</thead>
		<tbody>
			{#each rows as r, i (r.id)}
				{#if edit?.id === r.id}
					<tr class="editing">
						<td></td>
						<td><a href="/e/{r.slug}">{r.name}</a></td>
						<td>
							{#if valueEditable}
								{#if q.table === 'entity_states'}
									<select bind:value={edit.value}>{#each vocab.statuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}</select>
								{:else}
									<input bind:value={edit.value} aria-label="Value" />
									{#if q.table === 'addresses'}<input class="unit" bind:value={edit.unit} placeholder="Unit" aria-label="Unit" />{/if}
								{/if}
							{:else}{r.value}{/if}
						</td>
						<td class="when"><input bind:value={edit.from} placeholder="from" aria-label="From" /> – <input bind:value={edit.to} placeholder="until" aria-label="Until" /></td>
						<td><select bind:value={edit.conf}>{#each CONFIDENCES as c (c)}<option value={c}>{c}</option>{/each}</select></td>
						<td class="src"><SourcePicker sources={data.sources} bind:value={edit.src} allowNew={false} /></td>
						<td><input bind:value={edit.detail} aria-label="Where in it" /></td>
						<td>
							<input bind:value={edit.note} aria-label="Note" />
							<div class="row"><button class="ghost" onclick={() => (edit = null)}>Cancel</button><button class="primary" onclick={() => saveEdit(r)}>Save</button></div>
						</td>
					</tr>
				{:else}
					<tr class:selected={sel.has(r.id)} ondblclick={() => startEdit(r)}>
						<td class="tick"><input type="checkbox" checked={sel.has(r.id)} onclick={(e) => tick(i, e)} aria-label="Select" /></td>
						<td><a href="/e/{r.slug}">{r.name}</a><span class="meta">{r.kind}</span></td>
						<td>{r.value}</td>
						<td class="nowrap">{r.span}</td>
						<td class:warn={r.conf === 'disputed' || r.conf === 'speculative'}>{r.conf}</td>
						<td>{#if r.src_title}{r.src_title}{:else}<span class="uncited">uncited</span>{/if}</td>
						<td class="small">{r.detail ?? ''}</td>
						<td class="small">{r.note ?? ''}</td>
					</tr>
				{/if}
			{:else}
				<tr><td colspan="8" class="muted none">No records match.</td></tr>
			{/each}
		</tbody>
	</table>
</div>

<nav class="pager small">
	<span class="grow"></span>
	{#if pages > 1}
		<button class="ghost" disabled={data.pageNo <= 1} onclick={() => nav((u) => u.set('page', String(data.pageNo - 1)), true)}>‹ Prev</button>
		<span>Page {data.pageNo} of {pages}</span>
		<button class="ghost" disabled={data.pageNo >= pages} onclick={() => nav((u) => u.set('page', String(data.pageNo + 1)), true)}>Next ›</button>
	{/if}
	<label class="inline">Rows <select value={String(data.per)} onchange={(e) => setParam('per', (e.currentTarget as HTMLSelectElement).value)}>{#each [100, 250, 500] as n (n)}<option value={String(n)}>{n}</option>{/each}</select></label>
</nav>

{#if confirmDelete}
	<div class="backdrop" role="presentation" onclick={() => (confirmDelete = false)}></div>
	<div class="dialog" role="dialog" aria-modal="true" aria-label="Delete records">
		<h2>Delete {sel.size} record{sel.size === 1 ? '' : 's'}?</h2>
		<p class="small">They go in the open change set: undo them from there, or with Ctrl+Z.</p>
		<div class="row"><button class="ghost" onclick={() => (confirmDelete = false)}>Cancel</button><button class="primary danger-bg" onclick={del}>Delete {sel.size}</button></div>
	</div>
{/if}

{#if toast}
	<div class="toast {toast.kind}" role="status"><span>{toast.text}</span><button class="ghost" onclick={() => (toast = null)} aria-label="Dismiss">×</button></div>
{/if}

<style>
	.tables {
		display: flex;
		gap: 2px 16px;
		flex-wrap: wrap;
		border-bottom: 1px solid var(--line);
		margin-bottom: 10px;
	}
	.tables a {
		padding: 6px 0;
		margin-bottom: -1px;
		color: var(--ink-2);
		text-decoration: none;
		border-bottom: 2px solid transparent;
	}
	.tables a.on {
		color: var(--ink);
		border-bottom-color: var(--rust);
	}
	.filters {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		align-items: center;
	}
	.filters select,
	.filters input[type='search'] {
		width: auto;
	}
	.yr {
		width: 7ch;
	}
	.inline {
		display: inline-flex;
		gap: 6px;
		align-items: center;
		margin: 0;
	}
	.inline select {
		width: auto;
	}
	.grow {
		flex: 1;
	}
	.chips {
		display: flex;
		gap: 6px;
		margin-top: 8px;
	}
	.chip {
		padding: 3px 10px;
		border-radius: 999px;
		font-size: 0.82rem;
	}
	.bulkbar {
		position: sticky;
		top: var(--header-h);
		z-index: 20;
		display: flex;
		flex-wrap: wrap;
		gap: 6px 10px;
		align-items: center;
		padding: 8px 10px;
		margin-top: 10px;
		background: var(--bg);
		border-bottom: 1px solid var(--line);
	}
	.bulkbar.on {
		background: var(--panel);
		border: 1px solid var(--rust);
		border-radius: var(--radius);
	}
	.bulkbar button,
	.bulkbar select {
		padding: 5px 10px;
		width: auto;
	}
	.wrap {
		overflow: auto;
		border: 1px solid var(--line);
		border-radius: var(--radius);
	}
	table {
		font-size: 0.88rem;
		min-width: 100%;
	}
	th {
		position: sticky;
		top: 0;
		background: var(--panel);
		white-space: nowrap;
	}
	td {
		vertical-align: top;
	}
	.tick {
		width: 28px;
	}
	tr.selected td {
		background: rgba(194, 86, 43, 0.1);
	}
	tr.editing td {
		background: var(--panel-2);
	}
	tr.editing input,
	tr.editing select {
		padding: 4px 6px;
		font-size: 0.85rem;
	}
	.when input {
		width: 9ch;
	}
	.unit {
		width: 7ch;
		margin-top: 4px;
	}
	.src {
		min-width: 220px;
	}
	.meta {
		display: block;
		font-size: 0.74rem;
		color: var(--muted);
	}
	.nowrap {
		white-space: nowrap;
	}
	.uncited {
		color: var(--amber);
	}
	.warn {
		color: var(--amber);
	}
	.none {
		text-align: center;
		padding: 30px;
	}
	.pager {
		display: flex;
		gap: 10px;
		align-items: center;
		margin-top: 8px;
	}
	.danger-text {
		color: var(--danger);
	}
	.danger-bg {
		background: var(--danger);
		border-color: var(--danger);
	}
	.backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.5);
		z-index: 60;
	}
	.dialog {
		position: fixed;
		z-index: 61;
		left: 50%;
		top: 14vh;
		transform: translateX(-50%);
		width: min(460px, calc(100vw - 32px));
		background: var(--panel);
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		padding: 14px 16px;
		display: grid;
		gap: 10px;
	}
	.dialog h2 {
		margin: 0;
		font-size: 1.1rem;
	}
	.toast {
		position: fixed;
		z-index: 70;
		bottom: 18px;
		left: 50%;
		transform: translateX(-50%);
		display: flex;
		gap: 8px;
		align-items: center;
		padding: 9px 12px;
		border-radius: var(--radius);
		background: var(--panel);
		border: 1px solid var(--line-2);
	}
	.toast.ok {
		border-color: var(--moss);
	}
	.toast.error {
		border-color: var(--danger);
	}
	.toast.info {
		border-color: var(--sky);
	}
</style>
