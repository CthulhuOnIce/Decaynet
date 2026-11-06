<script lang="ts">
	import { goto, invalidateAll } from '$app/navigation';
	import { page } from '$app/state';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import { TABLE_LABELS, type LogRow } from '$lib/records';
	import LogTable from '../LogTable.svelte';
	import RecordsNav from '../RecordsNav.svelte';

	let { data } = $props();
	const f = $derived(data.f);
	const pages = $derived(Math.max(1, Math.ceil(data.total / data.per)));
	const setParam = (k: string, v: string | null) => {
		const u = new URLSearchParams(page.url.search);
		if (v) u.set(k, v);
		else u.delete(k);
		u.delete('p');
		goto(`?${u}`, { keepFocus: true, noScroll: true });
	};
	let toast = $state<{ text: string; kind: 'ok' | 'error' } | null>(null);
	async function revert(r: LogRow) {
		if (!data.hasSet) return (toast = { text: 'Open a change set first (Records › Pages, the bar at the top): taking a change back goes in it.', kind: 'error' });
		const res = await fetch('/admin/records/api', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ op: 'revert', log: r.id }) });
		const j = await res.json().catch(() => ({}));
		if (!res.ok) return (toast = { text: j.message ?? 'Something went wrong', kind: 'error' });
		if (!j.reverted) return (toast = { text: `Not taken back: ${j.conflict}.`, kind: 'error' });
		toast = { text: 'Taken back, in the open change set.', kind: 'ok' };
		await invalidateAll();
	}
</script>

<svelte:head><title>Audit log · Records · Admin</title></svelte:head>

<RecordsNav />

<section class="filters">
	<select aria-label="What" value={f.table} onchange={(e) => setParam('table', (e.currentTarget as HTMLSelectElement).value || null)}>
		<option value="">Everything</option>
		{#each Object.entries(TABLE_LABELS) as [id, label] (id)}<option value={id}>{label}s</option>{/each}
	</select>
	<select aria-label="Kind of change" value={f.op} onchange={(e) => setParam('op', (e.currentTarget as HTMLSelectElement).value || null)}>
		<option value="">Added, changed or removed</option>
		<option value="INSERT">Added</option>
		<option value="UPDATE">Changed</option>
		<option value="DELETE">Removed</option>
	</select>
	<select aria-label="Who" value={f.actor} onchange={(e) => setParam('actor', (e.currentTarget as HTMLSelectElement).value || null)}>
		<option value="">Anyone</option>
		{#each Object.entries(data.people) as [id, name] (id)}<option value={id}>{name}</option>{/each}
	</select>
	<div class="pick">
		<EntityPicker name="page_id" value={f.page ? { id: f.page, name: data.pageName ?? 'page' } : null} placeholder="On a page…" onpick={(p) => setParam('page_id', p?.id ?? null)} />
	</div>
	<label class="inline small">From <input type="date" value={f.since} onchange={(e) => setParam('since', (e.currentTarget as HTMLInputElement).value || null)} /></label>
	<label class="inline small">to <input type="date" value={f.until} onchange={(e) => setParam('until', (e.currentTarget as HTMLInputElement).value || null)} /></label>
	{#if f.set}<button class="chip" onclick={() => setParam('set', null)}>One change set ×</button>{/if}
</section>
<p class="muted small">{data.total.toLocaleString()} change{data.total === 1 ? '' : 's'}, newest first. “Take back” undoes one of them (anyone's) as part of your open change set, unless that record was changed again since.</p>

{#if data.rows.length}
	<LogTable rows={data.rows} names={data.names} sources={data.sources} tags={data.tags} people={data.people} onrevert={revert} />
{:else}
	<p class="muted">No changes match.</p>
{/if}
{#if pages > 1}
	<nav class="row small pager">
		{#if data.pageNo > 1}<a href="?{new URLSearchParams({ ...Object.fromEntries(page.url.searchParams), p: String(data.pageNo - 1) })}">‹ Newer</a>{/if}
		<span>Page {data.pageNo} of {pages}</span>
		{#if data.pageNo < pages}<a href="?{new URLSearchParams({ ...Object.fromEntries(page.url.searchParams), p: String(data.pageNo + 1) })}">Older ›</a>{/if}
	</nav>
{/if}
{#if toast}<div class="toast {toast.kind}" role="status"><span>{toast.text}</span><button class="ghost" onclick={() => (toast = null)} aria-label="Dismiss">×</button></div>{/if}

<style>
	.filters {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		align-items: center;
		margin-bottom: 8px;
	}
	.filters select {
		width: auto;
	}
	.pick {
		width: 240px;
	}
	.inline {
		display: inline-flex;
		gap: 6px;
		align-items: center;
		margin: 0;
	}
	.inline input {
		width: auto;
	}
	.chip {
		padding: 3px 10px;
		border-radius: 999px;
		font-size: 0.82rem;
	}
	.pager {
		margin-top: 10px;
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
</style>
