<script lang="ts">
	import { untrack } from 'svelte';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import type { Column, GridRow } from '$lib/records';

	interface Stub {
		name: string;
		first_name: string;
		unit: string;
		floor: string;
		address: string;
		tenant: { id: string; name: string } | null;
	}

	let {
		row,
		index,
		count,
		columns,
		year,
		api,
		onmove,
		onclose,
		onsaved,
		onconfirm
	}: {
		row: GridRow;
		index: number;
		count: number;
		columns: Column[];
		year: string;
		api: (body: unknown) => Promise<unknown>;
		/** go to another row (index), or past the end */
		onmove: (i: number) => void;
		onclose: () => void;
		onsaved: (after: number, label: string, text: string) => void;
		onconfirm: (row: GridRow) => void;
	} = $props();

	let spaces = $state<{ id: string; slug: string; name: string; depth: number }[] | null>(null);
	let stubs = $state<Stub[]>([]);
	let quick = $state('');
	let busy = $state(false);
	let problem = $state('');

	const blank = (): Stub => ({ name: '', first_name: '', unit: '', floor: '', address: '', tenant: null });

	// a new row: its spaces, an empty table
	$effect(() => {
		const id = row.id;
		untrack(() => {
			stubs = [blank()];
			quick = '';
			problem = '';
			spaces = null;
			api({ op: 'spaces', id })
				.then((s) => (spaces = s as typeof spaces))
				.catch(() => (spaces = []));
		});
	});

	const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
	/** "3 storefronts, 2 offices upstairs, a basement bar" → rows */
	function fromQuick() {
		const out: Stub[] = [];
		for (const raw of quick.split(/,|;|\band\b/i)) {
			let part = raw.trim();
			if (!part) continue;
			let n = 1;
			const m = part.match(/^(\d+|an?|one|two|three|four|five|six)\s+(.+)$/i);
			const words: Record<string, number> = { a: 1, an: 1, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6 };
			if (m) {
				n = /^\d+$/.test(m[1]) ? Number(m[1]) : (words[m[1].toLowerCase()] ?? 1);
				part = m[2];
			}
			let floor = '';
			if (/\bupstairs\b/i.test(part)) {
				floor = '2';
				part = part.replace(/\s*\bupstairs\b/i, '');
			}
			const f = part.match(/\s*(?:on\s+)?(?:the\s+)?(?:floor\s+(-?\d+)|(\d+)(?:st|nd|rd|th)\s+floor)/i);
			if (f) {
				floor = f[1] ?? f[2];
				part = part.replace(f[0], '');
			}
			if (/\bbasement\b/i.test(part)) floor = '-1';
			const one = n > 1 ? part.trim().replace(/ies$/i, 'y').replace(/([^s])s$/i, '$1') : part.trim();
			for (let i = 1; i <= Math.min(n, 50); i++) out.push({ ...blank(), name: cap(n > 1 ? `${one} ${i}` : one), unit: n > 1 && !floor ? String(i) : '', floor });
		}
		stubs = [...stubs.filter((s) => s.name.trim()), ...out];
		if (!stubs.length) stubs = [blank()];
		quick = '';
	}

	async function save(next: boolean) {
		const rows = stubs.filter((s) => s.name.trim());
		problem = '';
		if (!rows.length) {
			if (next) onmove(index + 1);
			return;
		}
		busy = true;
		try {
			const r = (await api({
				op: 'addSpaces',
				building: row.id,
				rows: rows.map((s) => ({ name: s.name, first_name: s.first_name, unit: s.unit, floor: s.floor, address: s.address, tenant: s.tenant?.id }))
			})) as { added: { name: string }[]; items: { outcome: string; reason?: string }[]; after: number };
			const skipped = r.items.filter((i) => i.outcome === 'skipped' || i.outcome === 'conflict');
			onsaved(r.after, `${r.added.length} spaces in ${row.name}`, `${row.name}: added ${r.added.map((a) => a.name).join(', ')}${skipped.length ? ` (a tenant wasn't linked: ${skipped[0].reason})` : ''}`);
			if (next) onmove(index + 1);
			else {
				stubs = [blank()];
				spaces = (await api({ op: 'spaces', id: row.id })) as typeof spaces;
			}
		} catch (e) {
			problem = (e as Error).message;
		} finally {
			busy = false;
		}
	}

	function key(e: KeyboardEvent) {
		if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
			e.preventDefault();
			save(true);
		} else if ((e.ctrlKey || e.metaKey) && e.key === 'ArrowRight') {
			e.preventDefault();
			onmove(index + 1);
		} else if ((e.ctrlKey || e.metaKey) && e.key === 'ArrowLeft') {
			e.preventDefault();
			onmove(index - 1);
		} else if (e.key === 'Escape' && !(e.target as HTMLElement).closest('.picker')) {
			e.preventDefault();
			onclose();
		}
	}
	const facts = $derived(columns.filter((c) => c.type === 'fact' && (row.cells[c.id] ?? []).length));
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<aside class="through" aria-label="Work through" onkeydown={key}>
	<div class="spread top">
		<span class="muted small">Row {index + 1} of {count} · as of {year}</span>
		<span class="row">
			<button class="ghost icon-btn" onclick={() => onmove(index - 1)} disabled={index === 0} title="Previous (Ctrl+←)">‹</button>
			<button class="ghost icon-btn" onclick={() => onmove(index + 1)} title="Skip (Ctrl+→)">›</button>
			<button class="ghost icon-btn" onclick={onclose} aria-label="Close" title="Close (Esc)">×</button>
		</span>
	</div>
	<h2><a href="/e/{row.slug}" target="_blank" rel="noopener">{row.name_then}</a></h2>
	<p class="muted small">
		{row.kind} · {row.span || 'undated'}{row.parent ? ` · in ${row.parent.name}` : ''}{row.side ? ` · ${row.side} side` : ''}{row.shape ? '' : ` · no shape in ${year}`}
	</p>
	{#if facts.length}
		<dl>
			{#each facts as c (c.id)}
				<dt>{c.short ?? c.label}</dt>
				<dd>{(row.cells[c.id] ?? []).map((f) => f.label).join(', ')}</dd>
			{/each}
		</dl>
	{/if}
	<button class="ghost small-btn" onclick={() => onconfirm(row)} title="Cite what this row shows as seen in {year}">Confirm what it shows</button>

	<h3>Spaces inside</h3>
	{#if spaces === null}
		<p class="muted small">…</p>
	{:else if spaces.length}
		<ul class="spaces">
			{#each spaces as s (s.id)}<li style="padding-left: {(s.depth - 1) * 14}px"><a href="/e/{s.slug}" target="_blank" rel="noopener">{s.name}</a></li>{/each}
		</ul>
	{:else}
		<p class="muted small">None yet.</p>
	{/if}

	<h3>Add spaces, as seen in {year}</h3>
	<form class="quick" onsubmit={(e) => (e.preventDefault(), fromQuick())}>
		<input bind:value={quick} placeholder="3 storefronts, 2 offices upstairs, a basement bar" aria-label="Describe the spaces" />
		<button class="ghost" disabled={!quick.trim()}>Fill</button>
	</form>
	<div class="stubs">
		{#each stubs as s, i (i)}
			<div class="stub">
				<input class="name" bind:value={s.name} placeholder="Storefront" aria-label="Name" />
				<input bind:value={s.first_name} placeholder="Called then" aria-label="Name then" title="What it was called in {year}, if not the page name" />
				<input class="tiny" bind:value={s.unit} placeholder="Unit" aria-label="Unit" />
				<input class="tiny" bind:value={s.floor} placeholder="Floor" aria-label="Floor" inputmode="numeric" />
				<input class="addr" bind:value={s.address} placeholder="514 (this street)" aria-label="Address" />
				<div class="tenant">
					<EntityPicker name="tenant-{i}" kinds={['organization', 'person']} value={s.tenant} placeholder="Tenant then…" onpick={(p) => (s.tenant = p ? { id: p.id, name: p.name } : null)} />
				</div>
				<button class="ghost icon-btn" onclick={() => (stubs = stubs.filter((_, k) => k !== i))} aria-label="Remove this row" disabled={stubs.length === 1}>×</button>
			</div>
		{/each}
		<button class="ghost small-btn" onclick={() => (stubs = [...stubs, blank()])}>+ Row</button>
	</div>
	{#if problem}<p class="notice error small">{problem}</p>{/if}
	<div class="spread foot">
		<span class="muted small">No shapes yet: draw them in the workbench. Ctrl+Enter saves and moves on.</span>
		<span class="row">
			<button class="ghost" onclick={() => save(false)} disabled={busy}>Save</button>
			<button class="primary" onclick={() => save(true)} disabled={busy}>{busy ? 'Saving…' : 'Save & next'}</button>
		</span>
	</div>
</aside>

<style>
	.through {
		position: fixed;
		z-index: 50;
		top: var(--header-h);
		right: 0;
		bottom: 0;
		width: min(560px, 100vw);
		overflow: auto;
		background: var(--panel);
		border-left: 1px solid var(--line-2);
		box-shadow: -10px 0 30px rgba(0, 0, 0, 0.4);
		padding: 12px 16px 20px;
	}
	h2 {
		margin: 4px 0 2px;
		font-size: 1.25rem;
	}
	h3 {
		font-size: 0.95rem;
		margin: 16px 0 6px;
	}
	dl {
		display: grid;
		grid-template-columns: max-content 1fr;
		gap: 2px 12px;
		font-size: 0.88rem;
		margin: 8px 0;
	}
	dt {
		color: var(--muted);
	}
	dd {
		margin: 0;
	}
	.spaces {
		list-style: none;
		margin: 0;
		padding: 0;
		font-size: 0.9rem;
	}
	.quick {
		display: flex;
		gap: 6px;
		margin-bottom: 8px;
	}
	.quick input {
		flex: 1;
	}
	.stubs {
		display: grid;
		gap: 6px;
	}
	.stub {
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
		padding-bottom: 6px;
		border-bottom: 1px dashed var(--line);
	}
	.stub input {
		padding: 5px 7px;
		font-size: 0.86rem;
		width: 130px;
	}
	.stub .name {
		width: 150px;
	}
	.stub .tiny {
		width: 62px;
	}
	.stub .addr {
		width: 120px;
	}
	.stub .tenant {
		flex: 1 1 150px;
		min-width: 150px;
	}
	.small-btn {
		padding: 4px 10px;
		font-size: 0.84rem;
	}
	.foot {
		margin-top: 12px;
	}
</style>
