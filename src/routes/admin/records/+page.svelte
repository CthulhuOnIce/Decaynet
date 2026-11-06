<script lang="ts">
	import { tick, untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import { goto, invalidateAll } from '$app/navigation';
	import { page } from '$app/state';
	import SourcePicker from '$lib/components/SourcePicker.svelte';
	import SourceFields from '$lib/components/SourceFields.svelte';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import { NEW_SOURCE } from '$lib/sources';
	import { SEARCH_PROPS } from '$lib/advancedSearch';
	import { toFuzzyInput } from '$lib/time';
	import { CONFIDENCES, type Vocabulary } from '$lib/types';
	import {
		CONFLICTS,
		MODES,
		PER_PAGE,
		SORTS,
		allColumns,
		readGrid,
		type Column,
		type ConflictRule,
		type GridRow,
		type WriteItem,
		type WriteSummary
	} from '$lib/records';
	import CellEditor, { type EditorSubmit } from './CellEditor.svelte';
	import Preview from './Preview.svelte';

	let { data, form } = $props();

	const vocab = $derived(page.data.vocab as Vocabulary);
	const grid = $derived(readGrid(new URLSearchParams(page.url.search)));
	const columns = $derived(allColumns(vocab));
	const shown = $derived(grid.cols.map((id) => columns.find((c) => c.id === id)).filter(Boolean) as Column[]);
	const rows = $derived(data.grid.rows as GridRow[]);
	const ctx = $derived(data.context);
	const year = $derived(data.at.slice(0, 4));
	const editing = $derived(!!data.current);
	const pages = $derived(Math.max(1, Math.ceil(data.grid.listed / grid.per)));

	// ------------------------------------------------------------ the URL (filters, columns, sort, page)
	function nav(change: (u: URLSearchParams) => void, keepPage = false) {
		const u = new URLSearchParams(page.url.search);
		change(u);
		if (!keepPage) u.delete('page');
		goto(`?${u}`, { keepFocus: true, noScroll: true, invalidateAll: true });
	}
	const setParam = (k: string, v: string | null) => nav((u) => (v ? u.set(k, v) : u.delete(k)));
	function setCols(ids: string[]) {
		nav((u) => u.set('cols', ids.join(',')), true);
	}
	function toggleCol(id: string) {
		setCols(grid.cols.includes(id) ? grid.cols.filter((c) => c !== id) : [...grid.cols, id]);
	}

	// filter chips: what's being asked for, each removable
	const chips = $derived.by(() => {
		const s = grid.search;
		const out: { label: string; drop: (u: URLSearchParams) => void }[] = [];
		if (grid.ids.length) out.push({ label: `${grid.ids.length} picked page${grid.ids.length === 1 ? '' : 's'}`, drop: (u) => u.delete('ids') });
		if (grid.inside) out.push({ label: 'Inside a building', drop: (u) => u.delete('inside') });
		if (s.q) out.push({ label: `“${s.q}”`, drop: (u) => u.delete('q') });
		for (const k of s.kinds) out.push({ label: vocab.kinds.find((x) => x.id === k)?.label ?? k, drop: (u) => dropValue(u, 'kind', k) });
		for (const st of s.statuses) out.push({ label: `${vocab.statuses.find((x) => x.id === st)?.label ?? st} then`, drop: (u) => dropValue(u, 'status', st) });
		if (s.statusNone) out.push({ label: 'No condition then', drop: (u) => u.delete('status_none') });
		for (const t of s.tags) out.push({ label: data.tags.find((x) => x.id === t)?.label ?? 'tag', drop: (u) => dropValue(u, 'tag', t) });
		for (const [k, v] of Object.entries(s.props)) {
			const p = [...SEARCH_PROPS, { id: 'spaces', label: 'Spaces' }].find((x) => x.id === k);
			out.push({ label: `${v === 'unset' ? 'No' : 'Has'} ${(p?.label ?? k).toLowerCase()}`, drop: (u) => u.delete(`has_${k}`) });
		}
		if (s.street || s.nfrom || s.nto) out.push({ label: `On ${s.street || 'a street'}${s.nfrom || s.nto ? ` ${s.nfrom || '…'}–${s.nto || '…'}` : ''}`, drop: (u) => ['street', 'nfrom', 'nto'].forEach((k) => u.delete(k)) });
		if (s.from || s.to) out.push({ label: `There ${s.from || '…'}–${s.to || '…'}`, drop: (u) => ['from', 'to'].forEach((k) => u.delete(k)) });
		return out;
	});
	function dropValue(u: URLSearchParams, k: string, v: string) {
		const keep = u.getAll(k).filter((x) => x !== v);
		u.delete(k);
		keep.forEach((x) => u.append(k, x));
	}
	let qText = $state(untrack(() => grid.search.q));
	$effect(() => {
		const q = grid.search.q;
		untrack(() => (qText = q));
	});
	const searchLink = $derived.by(() => {
		const u = new URLSearchParams(page.url.search);
		['cols', 'per', 'page', 'ids', 'inside', 'y'].forEach((k) => u.delete(k));
		if (!['relevance', 'name', 'start', 'end', 'updated'].includes(u.get('sort') ?? '')) u.delete('sort');
		return `/search/advanced?${u}`;
	});

	// ------------------------------------------------------------ selection
	let sel = $state<Set<string>>(new Set());
	let lastClicked = $state<number | null>(null);
	const allOnPage = $derived(rows.length > 0 && rows.every((r) => sel.has(r.id)));
	function toggleRow(i: number, e: MouseEvent | KeyboardEvent) {
		const next = new Set(sel);
		const on = !sel.has(rows[i].id);
		if (e.shiftKey && lastClicked !== null) {
			const [a, b] = [Math.min(lastClicked, i), Math.max(lastClicked, i)];
			for (let k = a; k <= b; k++) on ? next.add(rows[k].id) : next.delete(rows[k].id);
		} else on ? next.add(rows[i].id) : next.delete(rows[i].id);
		sel = next;
		lastClicked = i;
	}
	function togglePage() {
		const next = new Set(sel);
		if (allOnPage) rows.forEach((r) => next.delete(r.id));
		else rows.forEach((r) => next.add(r.id));
		sel = next;
	}
	let selectingAll = $state(false);
	async function selectAllMatching() {
		selectingAll = true;
		try {
			const r = (await api({ op: 'ids', search: page.url.search, at: data.at })) as { ids: string[] };
			sel = new Set(r.ids);
		} catch (e) {
			say((e as Error).message, 'error');
		} finally {
			selectingAll = false;
		}
	}
	/** The rows an action works on: the selection on this page, else the whole page. */
	const targetRows = () => (sel.size ? rows.filter((r) => sel.has(r.id)) : rows);

	// ------------------------------------------------------------ talking to the server
	async function api(body: unknown) {
		const r = await fetch('/admin/records/api', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
		const j = await r.json().catch(() => ({ message: r.statusText }));
		if (!r.ok) throw new Error(j.message ?? 'Something went wrong');
		return j;
	}

	type Toast = { text: string; kind: 'ok' | 'error' | 'info'; detail?: string[]; retry?: WriteItem[] };
	let toast = $state<Toast | null>(null);
	let toastTimer: ReturnType<typeof setTimeout> | undefined;
	function say(text: string, kind: Toast['kind'] = 'ok', extra: Partial<Toast> = {}) {
		toast = { text, kind, ...extra };
		clearTimeout(toastTimer);
		if (kind === 'ok' && !extra.retry) toastTimer = setTimeout(() => (toast = null), 6000);
	}

	/** What this session did, newest last: each can be taken back (Ctrl+Z). */
	let undoStack = $state<{ after: number; label: string }[]>([]);
	let undoing = $state(false);
	async function undoLast() {
		const last = undoStack.at(-1);
		if (!last || undoing) return;
		undoing = true;
		try {
			const r = (await api({ op: 'undoLast', after: last.after })) as { undone: boolean; conflicts: { name: string | null }[] };
			if (!r.undone) say(`Can't undo “${last.label}”: ${r.conflicts.map((c) => c.name ?? 'a page').slice(0, 3).join(', ')} changed since.`, 'error');
			else {
				undoStack = undoStack.slice(0, -1);
				say(`Undid: ${last.label}`, 'info');
				await invalidateAll();
			}
		} catch (e) {
			say((e as Error).message, 'error');
		} finally {
			undoing = false;
		}
	}

	let preview = $state<{ title: string; items: WriteItem[]; summary: WriteSummary; conflict: ConflictRule } | null>(null);
	let applying = $state(false);

	const describe = (s: WriteSummary) =>
		[s.changed && `${s.changed} changed`, s.cited && `${s.cited} cited`, s.already && `${s.already} already so`, s.skipped && `${s.skipped} skipped`, s.conflict && `${s.conflict} in conflict`]
			.filter(Boolean)
			.join(', ') || 'Nothing to do';

	/** One item applies straight away; more are previewed first. */
	async function run(items: WriteItem[], title: string, conflict: ConflictRule = ctx.conflict) {
		if (!editing) return say('Set the year and the source you’re working from first (the bar at the top).', 'error');
		if (!items.length) return say('Nothing to change.', 'info');
		const withRule = items.map((it) => ({ ...it, conflict: it.conflict ?? conflict }));
		try {
			if (items.length === 1) {
				const s = (await api({ op: 'write', items: withRule })) as WriteSummary;
				const r = s.items[0];
				if (r.outcome === 'conflict') say(`${r.name}: ${r.reason}`, 'error', { retry: withRule });
				else if (r.outcome === 'skipped') say(`${r.name ?? 'Skipped'}: ${r.reason}`, 'error');
				else if (r.outcome === 'already') say(`${r.name}: already so${r.when ? ` in ${r.when}` : ''}.`, 'info');
				else {
					say(`${r.name}: ${r.steps?.join('; ')}`, 'ok');
					if (s.after !== null) undoStack = [...undoStack, { after: s.after, label: title }];
				}
				await invalidateAll();
				return;
			}
			const summary = (await api({ op: 'write', items: withRule, preview: true })) as WriteSummary;
			preview = { title, items, summary, conflict };
		} catch (e) {
			say((e as Error).message, 'error');
		}
	}
	async function recheck(c: ConflictRule) {
		if (!preview) return;
		const p = preview;
		try {
			const summary = (await api({ op: 'write', items: p.items.map((it) => ({ ...it, conflict: c })), preview: true })) as WriteSummary;
			preview = { ...p, summary, conflict: c };
		} catch (e) {
			say((e as Error).message, 'error');
		}
	}
	async function applyPreview() {
		if (!preview) return;
		applying = true;
		const p = preview;
		try {
			const s = (await api({ op: 'write', items: p.items.map((it) => ({ ...it, conflict: p.conflict })) })) as WriteSummary;
			if (s.after !== null && s.changed + s.cited) undoStack = [...undoStack, { after: s.after, label: p.title }];
			say(`${p.title}: ${describe(s)}.`, s.skipped || s.conflict ? 'info' : 'ok');
			preview = null;
			await invalidateAll();
		} catch (e) {
			say((e as Error).message, 'error');
		} finally {
			applying = false;
		}
	}
	async function retryWith(c: ConflictRule) {
		const items = toast?.retry;
		if (!items) return;
		toast = null;
		await run(
			items.map((it) => ({ ...it, conflict: c })),
			'Edit',
			c
		);
	}

	async function patchPages(ids: string[], patch: Record<string, unknown>, label: string) {
		if (!editing) return say('Open a change set first (the bar at the top).', 'error');
		try {
			const r = (await api({ op: 'pages', ids, patch })) as { changed: number; after: number };
			undoStack = [...undoStack, { after: r.after, label }];
			say(`${label}: ${r.changed} page${r.changed === 1 ? '' : 's'}.`);
			await invalidateAll();
		} catch (e) {
			say((e as Error).message, 'error');
		}
	}

	// ------------------------------------------------------------ cells: focus, editing, paste
	let focus = $state<{ r: number; c: number } | null>(null);
	let edit = $state<{ r: number; c: number; initial: string } | null>(null);
	let gridEl: HTMLDivElement;
	let editorPos = $state({ top: 0, left: 0 });

	const editable = (c: Column) => c.type !== 'info';
	async function openEditor(r: number, c: number, initial = '') {
		const col = shown[c];
		if (!col || !editable(col)) return;
		if (!editing && col.type === 'fact' && ctx.mode !== 'correct') return say('Set the year and the source you’re working from first (the bar at the top).', 'error');
		focus = { r, c };
		edit = { r, c, initial };
		await tick();
		const cell = gridEl?.querySelector<HTMLElement>(`[data-cell="${r}:${c}"]`);
		if (cell) {
			const wrap = gridEl.getBoundingClientRect();
			const b = cell.getBoundingClientRect();
			editorPos = { top: b.bottom - wrap.top + gridEl.scrollTop + 2, left: Math.max(0, Math.min(b.left - wrap.left + gridEl.scrollLeft, gridEl.scrollWidth - 340)) };
		}
	}
	function closeEditor() {
		edit = null;
		gridEl?.focus({ preventScroll: true });
	}
	const editorTargets = (r: number) => (sel.has(rows[r].id) && sel.size > 1 ? [...sel] : [rows[r].id]);

	async function submitEditor(s: EditorSubmit) {
		if (!edit) return;
		const col = shown[edit.c];
		const ids = editorTargets(edit.r);
		const one = ids.length === 1 ? rows[edit.r].name_then : `${ids.length} pages`;
		closeEditor();
		if (s.kind === 'page') return patchPages(ids, s.patch, `${col.label} for ${one}`);
		const items: WriteItem[] = ids.map((entity) => ({
			entity,
			field: col.id,
			op: s.op,
			value: s.value,
			mode: s.mode,
			...(s.mode === 'only' ? { to: s.to, to_p: s.to_p } : {})
		}));
		await run(items, `${col.label} for ${one}`);
	}

	function moveFocus(dr: number, dc: number) {
		const f = focus ?? { r: 0, c: 0 };
		const r = Math.max(0, Math.min(rows.length - 1, f.r + dr));
		const c = Math.max(0, Math.min(shown.length - 1, f.c + dc));
		focus = { r, c };
		tick().then(() => gridEl?.querySelector<HTMLElement>(`[data-cell="${r}:${c}"]`)?.scrollIntoView({ block: 'nearest', inline: 'nearest' }));
	}

	function gridKey(e: KeyboardEvent) {
		if (edit || (e.target as HTMLElement).closest('input, select, textarea, .editor')) return;
		const k = e.key;
		if ((e.ctrlKey || e.metaKey) && k.toLowerCase() === 'z') {
			e.preventDefault();
			undoLast();
			return;
		}
		if ((e.ctrlKey || e.metaKey) && k.toLowerCase() === 'a') {
			e.preventDefault();
			togglePage();
			return;
		}
		if (!rows.length) return;
		const moves: Record<string, [number, number]> = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] };
		if (moves[k]) {
			e.preventDefault();
			moveFocus(...moves[k]);
		} else if (k === 'Tab' && focus) {
			e.preventDefault();
			moveFocus(0, e.shiftKey ? -1 : 1);
		} else if ((k === 'Enter' || k === 'F2') && focus) {
			e.preventDefault();
			openEditor(focus.r, focus.c);
		} else if (k === ' ' && focus) {
			e.preventDefault();
			toggleRow(focus.r, e);
		} else if (k === 'Escape') {
			if (sel.size) sel = new Set();
			else focus = null;
		} else if (focus && k.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey && ['text', 'number', 'address'].includes(shown[focus.c]?.input)) {
			e.preventDefault();
			openEditor(focus.r, focus.c, k);
		}
	}

	/** Paste a column from a spreadsheet: one value per row, from the focused cell down. */
	function gridPaste(e: ClipboardEvent) {
		if (edit || !focus || (e.target as HTMLElement).closest('input, select, textarea')) return;
		const text = e.clipboardData?.getData('text/plain') ?? '';
		const lines = text.replace(/\r/g, '').split('\n');
		while (lines.length && !lines.at(-1)?.trim()) lines.pop();
		if (!lines.length) return;
		e.preventDefault();
		const col = shown[focus.c];
		if (!col || col.type !== 'fact') return say('Paste into a column of facts (a name, condition, address, tag or fact).', 'error');
		const items: WriteItem[] = [];
		const bad: string[] = [];
		lines.forEach((raw, i) => {
			const row = rows[focus!.r + i];
			const v = raw.split('\t')[0].trim();
			if (!row || !v) return;
			let value: unknown = v;
			if (col.input === 'status') {
				value = vocab.statuses.find((s) => s.id === v || s.label.toLowerCase() === v.toLowerCase())?.id;
				if (!value) bad.push(v);
			} else if (col.input === 'tag') {
				value = data.tags.find((t) => t.label.toLowerCase() === v.toLowerCase() || t.path.toLowerCase() === v.toLowerCase())?.id;
				if (!value) bad.push(v);
			} else if (col.input === 'address') {
				const cur = (row.cells.address?.[0]?.v ?? {}) as { street_id?: string };
				value = /^\d+[a-z]?$/i.test(v) && cur.street_id ? { street_id: cur.street_id, house_number: v } : { text: v };
			} else if (col.input === 'entity') {
				bad.push(v);
				value = undefined;
			}
			if (value !== undefined) items.push({ entity: row.id, field: col.id, op: col.multi ? 'add' : 'set', value });
		});
		if (bad.length) say(`Not recognised: ${bad.slice(0, 5).join(', ')}${bad.length > 5 ? '…' : ''}${col.input === 'entity' ? ' (pick pages with the editor instead)' : ''}`, 'error');
		if (items.length) run(items, `Pasted ${col.label.toLowerCase()} into ${items.length} row${items.length === 1 ? '' : 's'}`);
	}

	// ------------------------------------------------------------ bulk tools
	let fill = $state<{ col: string; start: number; step: number; sides: boolean; oddSide: string; template: string; street: { id: string; name: string } | null } | null>(null);
	const sidesHere = $derived([...new Set(rows.map((r) => r.side).filter(Boolean))] as string[]);
	function openFill() {
		const c = focus ? shown[focus.c] : null;
		const col = c && c.type === 'fact' && (c.input === 'address' || c.input === 'text' || c.input === 'number') ? c.id : grid.cols.includes('address') ? 'address' : (shown.find((x) => x.type === 'fact')?.id ?? 'address');
		const cur = targetRows()[0]?.cells.address?.[0];
		fill = { col, start: 100, step: 2, sides: sidesHere.length === 2, oddSide: sidesHere[0] ?? 'north', template: 'Storefront {n}', street: cur ? { id: (cur.v as { street_id: string }).street_id, name: cur.label.replace(/^\S+\s+/, '') } : null };
	}
	function fillItems(): WriteItem[] {
		if (!fill) return [];
		const f = fill;
		const col = columns.find((c) => c.id === f.col);
		const list = targetRows();
		const out: WriteItem[] = [];
		const count: Record<string, number> = {};
		for (const r of list) {
			const side = f.sides && r.side ? r.side : '_';
			const k = (count[side] = (count[side] ?? -1) + 1);
			let n = f.start + k * f.step;
			if (f.sides && r.side) {
				// odd numbers on one side of the street, even on the other
				const wantOdd = r.side === f.oddSide;
				if (Math.abs(n % 2) === 1 !== wantOdd) n += 1;
			}
			if (col?.input === 'address') {
				const street = f.street?.id ?? (r.cells.address?.[0]?.v as { street_id?: string } | undefined)?.street_id;
				out.push({ entity: r.id, field: 'address', op: 'set', value: { street_id: street, house_number: String(n) } });
			} else if (col) out.push({ entity: r.id, field: col.id, op: 'set', value: col.input === 'number' ? n : f.template.replace('{n}', String(n)) });
		}
		return out;
	}
	async function previewFill() {
		const items = fillItems();
		const col = columns.find((c) => c.id === fill?.col);
		fill = null;
		await run(items, `Numbered ${col?.label.toLowerCase() ?? ''} on ${items.length} rows`);
	}

	/** Confirm what each row shows, as seen in the context year (cites it, joins it up). */
	async function confirmRows() {
		const items: WriteItem[] = [];
		for (const r of targetRows())
			for (const c of shown.filter((x) => x.type === 'fact'))
				for (const f of r.cells[c.id] ?? []) items.push({ entity: r.id, field: c.id, op: c.multi ? 'add' : 'set', value: f.v, mode: 'seen' });
		await run(items, `Confirmed ${targetRows().length} rows as seen in ${year}`);
	}

	let del = $state<{ typed: string; spaces: boolean } | null>(null);
	let deleting = $state(false);
	async function doDelete() {
		if (!del) return;
		deleting = true;
		try {
			const ids = [...sel];
			const r = (await api({ op: 'delete', ids, expect: Number(del.typed), spaces: del.spaces })) as { deleted: number; after: number };
			undoStack = [...undoStack, { after: r.after, label: `Deleted ${r.deleted} pages` }];
			say(`Deleted ${r.deleted} page${r.deleted === 1 ? '' : 's'}. Ctrl+Z or “Undo last” brings them back.`);
			sel = new Set();
			del = null;
			await invalidateAll();
		} catch (e) {
			say((e as Error).message, 'error');
		} finally {
			deleting = false;
		}
	}

	function exportCsv() {
		const list = targetRows();
		const esc = (v: string) => (/[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
		const head = ['Page', 'Kind', 'Link', 'Lifespan', ...shown.map((c) => c.label)];
		const body = list.map((r) => [r.name, r.kind, `${page.url.origin}/e/${r.slug}`, r.span, ...shown.map((c) => cellText(r, c))]);
		const csv = [head, ...body].map((l) => l.map((v) => esc(String(v ?? ''))).join(',')).join('\n');
		const a = document.createElement('a');
		a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
		a.download = `records-${year}.csv`;
		a.click();
		URL.revokeObjectURL(a.href);
	}

	function cellText(r: GridRow, c: Column): string {
		if (c.id === 'lifespan') return r.span;
		if (c.id === 'parent') return r.parent?.name ?? '';
		if (c.id === 'spaces') return r.spaces ? String(r.spaces) : '';
		if (c.id === 'shape') return r.shape ? 'yes' : '';
		if (c.id === 'summary') return r.summary ?? '';
		return (r.cells[c.id] ?? []).map((f) => f.label).join('; ');
	}

	// ------------------------------------------------------------ the context bar
	// svelte-ignore state_referenced_locally
	let sourceId = $state(data.context.source_id ?? '');
	// svelte-ignore state_referenced_locally
	let mode = $state(data.context.mode);
	$effect(() => {
		const c = data.context;
		untrack(() => {
			sourceId = c.source_id ?? '';
			mode = c.mode;
		});
	});
	let fresh = $state(false);
	// on a phone, an open set folds the bar to one line
	let ctxOpen = $state(true);
	$effect(() => {
		const narrow = window.matchMedia('(max-width: 700px)').matches;
		const live = editing;
		untrack(() => (ctxOpen = !(narrow && live)));
	});
	let savingCtx = $state(false);
	const atInput = $derived(ctx.at ? toFuzzyInput(ctx.at, ctx.at_p as never) : grid.year);
	const toInput = $derived(ctx.to ? toFuzzyInput(ctx.to, ctx.to_p as never) : '');
	const changeCount = $derived(data.current?.changes ?? 0);
	const others = $derived(data.sets.filter((s) => s.id !== data.current?.id && !s.undone_at));

	// keep the selection to rows that still exist after a reload
	$effect(() => {
		const ids = new Set(rows.map((r) => r.id));
		if (focus && focus.r >= rows.length) untrack(() => (focus = null));
		void ids;
	});
</script>

<svelte:head><title>Records · Admin</title></svelte:head>

<!-- ======================================================== context -->
<section class="context" class:live={editing} aria-label="What you're working from">
	{#if !ctxOpen}
		<button class="ctx-summary" onclick={() => (ctxOpen = true)}>
			<strong>{ctx.at ? toFuzzyInput(ctx.at, ctx.at_p as never) : year}</strong> · {MODES.find((m) => m.id === ctx.mode)?.label} ·
			{data.sources.find((s) => s.id === ctx.source_id)?.title ?? 'a source'} <span class="muted">· change</span>
		</button>
	{/if}
	<form
		hidden={!ctxOpen}
		method="post"
		action="?/context"
		class="ctx-form"
		use:enhance={() => {
			savingCtx = true;
			return async ({ update, result }) => {
				await update({ reset: false });
				savingCtx = false;
				fresh = false;
				if (result.type === 'success') undoStack = [];
			};
		}}
	>
		<input type="hidden" name="fresh" value={fresh ? '1' : '0'} />
		<label class="f year"><span>As of</span><input name="at" value={atInput} placeholder="1925" required aria-label="Year" /></label>
		{#if mode === 'only' || toInput}
			<label class="f year"><span>to</span><input name="to" value={toInput} placeholder="1930" aria-label="Until" /></label>
		{/if}
		<div class="f">
			<span>Edits land</span>
			<div class="pills" role="radiogroup" aria-label="How edits land in time">
				{#each MODES as m (m.id)}
					<label class="pill" class:on={mode === m.id} title={m.hint}><input type="radio" name="mode" value={m.id} bind:group={mode} />{m.label}</label>
				{/each}
			</div>
		</div>
		<div class="f src">
			<span>Citing</span>
			<SourcePicker name="source_id" sources={data.sources} bind:value={sourceId} allowNone={false} newLabel="New source…" placeholder="The map, directory or photo you're working from…" />
		</div>
		<label class="f detail"><span>Where in it</span><input name="source_detail" value={ctx.source_detail ?? ''} placeholder="sheet 14, p. 214" /></label>
		<label class="f conf"
			><span>Confidence</span>
			<select name="confidence" value={ctx.confidence}>
				{#each CONFIDENCES as c (c)}<option value={c}>{c}</option>{/each}
			</select></label
		>
		<label class="f conf"
			><span>If another source disagrees</span>
			<select name="conflict" value={ctx.conflict}>
				{#each CONFLICTS as c (c.id)}<option value={c.id}>{c.label}</option>{/each}
			</select></label
		>
		<div class="f actions">
			<button class="primary" disabled={savingCtx}>{editing ? 'Update' : 'Start editing'}</button>
			{#if editing}<button class="ghost" onclick={() => (fresh = true)} title="Keep the current change set as it is and start another">New set</button>{/if}
		</div>
		{#if sourceId === NEW_SOURCE}
			<div class="newsrc"><SourceFields prefix="ns_" idPrefix="rc-ns" kind="map" note="Saved to the source library, so you can pick it again." /></div>
		{/if}
	</form>
	<div class="set-line small">
		{#if data.current}
			<span><strong>{data.current.title || 'Untitled set'}</strong> · {changeCount} change{changeCount === 1 ? '' : 's'}{data.current.pages ? ` to ${data.current.pages} page${data.current.pages === 1 ? '' : 's'}` : ''}</span>
			{#if undoStack.length}<button class="linkish" onclick={undoLast} disabled={undoing} title="Ctrl+Z">Undo “{undoStack.at(-1)?.label}”</button>{/if}
			<a href="/admin/records/sets/{data.current.id}">Review</a>
			<form method="post" action="?/undoSet" use:enhance={({ cancel }) => { if (!confirm(`Undo all ${changeCount} changes in “${data.current?.title}”?`)) cancel(); return async ({ update }) => { undoStack = []; await update(); }; }}>
				<button class="linkish danger-text">Undo the whole set</button>
			</form>
			<form method="post" action="?/switch" use:enhance><input type="hidden" name="set" value="" /><button class="linkish">Close it</button></form>
		{:else}
			<span class="muted">Looking at {year}. Set a year and the source you're working from to start editing: every edit is dated and cited from here, and kept together as a change set you can review or undo.</span>
		{/if}
		{#if others.length}
			<form method="post" action="?/switch" use:enhance class="switch">
				<select name="set" aria-label="Carry on with an earlier change set" onchange={(e) => (e.currentTarget as HTMLSelectElement).form?.requestSubmit()}>
					<option value="">Earlier sets…</option>
					{#each others as s (s.id)}<option value={s.id}>{s.title || 'Untitled'} ({s.changes})</option>{/each}
				</select>
			</form>
		{/if}
		<a href="/admin/records/sets">All change sets</a>
	</div>
	{#if form && 'error' in form && form.error}
		<p class="notice error small">
			{form.error}
			{#if 'conflicts' in form && form.conflicts}
				{(form.conflicts as { name: string | null }[]).map((c) => c.name ?? 'a page').slice(0, 6).join(', ')}
			{/if}
		</p>
	{/if}
	{#if form && 'undoneSet' in form}<p class="notice ok small">Undid {form.undoneSet} changes.</p>{/if}
</section>

<!-- ======================================================== filters -->
<section class="filters" aria-label="Which pages">
	<form class="q" onsubmit={(e) => (e.preventDefault(), setParam('q', qText.trim() || null))}>
		<input type="search" bind:value={qText} placeholder="Find by name, any name it had…" aria-label="Search" />
	</form>
	<select aria-label="Kind" value={grid.search.kinds.length === 1 ? grid.search.kinds[0] : ''} onchange={(e) => nav((u) => { u.delete('kind'); const v = (e.currentTarget as HTMLSelectElement).value; if (v) u.set('kind', v); if (!u.get('cols')) u.delete('cols'); })}>
		<option value="">All kinds</option>
		{#each vocab.kinds as k (k.id)}<option value={k.id}>{k.label}</option>{/each}
	</select>
	<select aria-label="Missing" value="" onchange={(e) => { const v = (e.currentTarget as HTMLSelectElement).value; if (v) setParam(`has_${v}`, 'unset'); }}>
		<option value="">Missing…</option>
		{#each [...SEARCH_PROPS, { id: 'spaces', label: 'Spaces' }] as p (p.id)}<option value={p.id}>No {p.label.toLowerCase()}</option>{/each}
	</select>
	<div class="inside">
		<EntityPicker name="inside" kinds={['building', 'space', 'site']} placeholder="Inside a building…" onpick={(p) => p && nav((u) => { u.set('inside', p.id); u.set('sort', 'tree'); })} />
	</div>
	<a class="btn ghost" href={searchLink}>More filters…</a>
	<span class="grow"></span>
	<label class="inline small">Sort
		<select value={grid.sort} onchange={(e) => setParam('sort', (e.currentTarget as HTMLSelectElement).value)}>
			{#each SORTS as s (s.id)}<option value={s.id}>{s.label}</option>{/each}
		</select>
	</label>
	<details class="cols">
		<summary class="btn ghost">Columns ({shown.length})</summary>
		<div class="col-menu">
			{#each [['On the page', columns.filter((c) => !c.id.includes(':'))], ['Facts', columns.filter((c) => c.id.startsWith('attr:'))], ['Links', columns.filter((c) => c.id.startsWith('rel:'))]] as [label, list] (label)}
				<div class="col-group">
					<div class="eyebrow">{label}</div>
					{#each list as Column[] as c (c.id)}
						<label class="check"><input type="checkbox" checked={grid.cols.includes(c.id)} onchange={() => toggleCol(c.id)} /> {c.label}</label>
					{/each}
				</div>
			{/each}
		</div>
	</details>
</section>
{#if chips.length}
	<div class="chips" aria-label="Filters">
		{#each chips as ch, i (i)}<button class="chip" onclick={() => nav(ch.drop)} title="Remove this filter">{ch.label} ×</button>{/each}
		<button class="linkish small" onclick={() => goto('?', { invalidateAll: true })}>Clear all</button>
	</div>
{/if}

<!-- ======================================================== bulk -->
<div class="bulkbar" class:on={sel.size > 0}>
	{#if sel.size}
		<strong>{sel.size} selected</strong>
		{#if allOnPage && data.grid.listed > rows.length && sel.size < data.grid.listed}
			<button class="linkish" onclick={selectAllMatching} disabled={selectingAll}>Select all {data.grid.listed} matching</button>
		{/if}
		<span class="muted small">Edit a cell to change all of them.</span>
	{:else}
		<span class="muted small">{data.grid.total} page{data.grid.total === 1 ? '' : 's'}{data.grid.total > data.grid.listed ? ` (the first ${data.grid.listed} listed; narrow the filters)` : ''} · as of {year} · tick rows (Shift for a run) to work on several</span>
	{/if}
	<span class="grow"></span>
	<button class="ghost" onclick={openFill} disabled={!rows.length} title="Number the selected rows in order (house numbers, storefronts…)">Fill series…</button>
	<button class="ghost" onclick={confirmRows} disabled={!rows.length || !editing} title="Each row's values, seen in {year}: cited and joined up">Confirm {sel.size ? 'selected' : 'page'}</button>
	<button class="ghost" onclick={exportCsv} disabled={!rows.length}>CSV</button>
	{#if sel.size}<button class="ghost danger-text" onclick={() => (del = { typed: '', spaces: false })} disabled={!editing}>Delete…</button>{/if}
	{#if sel.size}<button class="ghost" onclick={() => (sel = new Set())}>Untick</button>{/if}
</div>

<!-- ======================================================== grid -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<div class="grid-wrap" bind:this={gridEl} tabindex="0" onkeydown={gridKey} onpaste={gridPaste} role="grid" aria-label="Records" aria-rowcount={rows.length}>
	<table>
		<thead>
			<tr>
				<th class="tick"><input type="checkbox" checked={allOnPage} onchange={togglePage} aria-label="Select this page" /></th>
				<th class="pagecol">Page</th>
				{#each shown as c (c.id)}
					<th class:ro={!editable(c)}>
						{c.short ?? c.label}{#if c.unit}<span class="muted"> ({c.unit})</span>{/if}
						<button class="x" onclick={() => toggleCol(c.id)} aria-label="Hide {c.label}" title="Hide">×</button>
					</th>
				{/each}
			</tr>
		</thead>
		<tbody>
			{#each rows as r, i (r.id)}
				<tr class:selected={sel.has(r.id)} class:absent={!r.there}>
					<td class="tick"><input type="checkbox" checked={sel.has(r.id)} onclick={(e) => toggleRow(i, e)} aria-label="Select {r.name}" /></td>
					<td class="pagecol" style="padding-left: {8 + r.depth * 16}px">
						<a href="/e/{r.slug}" target="_blank" rel="noopener">{r.name}</a>
						<span class="meta">{r.kind}{r.side ? ` · ${r.side} side` : ''}{r.private ? ' · private' : ''}{r.there ? '' : ` · not there in ${year}`}</span>
					</td>
					{#each shown as c, j (c.id)}
						{@const facts = r.cells[c.id] ?? []}
						<td
							data-cell="{i}:{j}"
							class:focus={focus?.r === i && focus?.c === j}
							class:ro={!editable(c)}
							onclick={() => (focus = { r: i, c: j })}
							ondblclick={() => openEditor(i, j)}
						>
							{#if c.id === 'name' && !facts.length}
								<span class="implicit" title="No dated name: the page title">{r.name_then}</span>
							{:else if c.type === 'fact'}
								{#each facts as f (f.id)}
									<span class="fact" class:multi={c.multi} title="{f.span}{f.src_title ? ` · ${f.src_title}${f.detail ? `, ${f.detail}` : ''}` : ' · uncited'} · {f.conf}">
										{f.label}<span class="cite" class:none={!f.src}>{f.src ? '◆' : '○'}</span>
									</span>
								{:else}
									<span class="empty">—</span>
								{/each}
							{:else}
								{@const t = cellText(r, c)}
								{#if c.id === 'parent' && r.parent}<a href="/e/{r.parent.slug}" target="_blank" rel="noopener">{r.parent.name}</a>
								{:else if c.id === 'spaces' && r.spaces}<a href="?inside={r.id}&sort=tree&cols={encodeURIComponent(grid.cols.join(','))}">{r.spaces}</a>
								{:else if t}<span class="plain">{t}</span>
								{:else}<span class="empty">—</span>{/if}
							{/if}
						</td>
					{/each}
				</tr>
			{:else}
				<tr><td colspan={shown.length + 2} class="none muted">Nothing matches. Loosen the filters, or open a selection from the workbench.</td></tr>
			{/each}
		</tbody>
	</table>
	{#if edit && rows[edit.r] && shown[edit.c]}
		<div class="editor-at" style="top: {editorPos.top}px; left: {editorPos.left}px">
			<CellEditor
				col={shown[edit.c]}
				row={rows[edit.r]}
				context={ctx}
				statuses={vocab.statuses}
				tags={data.tags}
				count={editorTargets(edit.r).length}
				initial={edit.initial}
				onsubmit={submitEditor}
				oncancel={closeEditor}
			/>
		</div>
	{/if}
</div>

<nav class="pager small" aria-label="Pages">
	<span class="muted">Keys: arrows move · Enter edits · Space ticks · Ctrl+V pastes a column · Ctrl+Z undoes</span>
	<span class="grow"></span>
	{#if pages > 1}
		<button class="ghost" disabled={grid.page <= 1} onclick={() => nav((u) => u.set('page', String(grid.page - 1)), true)}>‹ Prev</button>
		<span>Page {grid.page} of {pages}</span>
		<button class="ghost" disabled={grid.page >= pages} onclick={() => nav((u) => u.set('page', String(grid.page + 1)), true)}>Next ›</button>
	{/if}
	<label class="inline">Rows
		<select value={String(grid.per)} onchange={(e) => setParam('per', (e.currentTarget as HTMLSelectElement).value)}>
			{#each PER_PAGE as n (n)}<option value={String(n)}>{n}</option>{/each}
		</select>
	</label>
</nav>

<!-- ======================================================== dialogs -->
{#if toast}
	<div class="toast {toast.kind}" role="status">
		<span>{toast.text}</span>
		{#if toast.retry}
			<button class="ghost" onclick={() => retryWith('dispute')}>Add mine as disputed</button>
			<button class="ghost" onclick={() => retryWith('trim')}>Cut it back anyway</button>
		{/if}
		<button class="ghost x" onclick={() => (toast = null)} aria-label="Dismiss">×</button>
	</div>
{/if}

{#if preview}
	<Preview title={preview.title} summary={preview.summary} conflict={preview.conflict} busy={applying} onapply={applyPreview} onrecheck={recheck} oncancel={() => (preview = null)} />
{/if}

{#if fill}
	<div class="backdrop" role="presentation" onclick={() => (fill = null)}></div>
	<div class="dialog" role="dialog" aria-modal="true" aria-label="Fill series">
		<h2>Fill series</h2>
		<p class="muted small">Numbers {sel.size ? 'the selected rows' : 'every row on this page'} in the order shown{grid.sort === 'name' ? ' (sort west → east or north → south first for a block)' : ''}.</p>
		<div class="fields">
			<label>Column
				<select bind:value={fill.col}>
					{#each columns.filter((c) => c.type === 'fact' && ['address', 'text', 'number'].includes(c.input)) as c (c.id)}<option value={c.id}>{c.label}</option>{/each}
				</select>
			</label>
			<label>Start at <input type="number" bind:value={fill.start} /></label>
			<label>Step <input type="number" bind:value={fill.step} /></label>
		</div>
		{#if fill.col === 'address'}
			<div class="field"><span class="lbl">Street</span><EntityPicker name="fill_street" kinds={['street']} value={fill.street} placeholder="Keep each row's street" onpick={(p) => fill && (fill.street = p ? { id: p.id, name: p.name } : null)} /></div>
			{#if sidesHere.length === 2}
				<label class="check"><input type="checkbox" bind:checked={fill.sides} /> Odd numbers on one side of the street, even on the other</label>
				{#if fill.sides}
					<label>Odd numbers on the
						<select bind:value={fill.oddSide}>{#each sidesHere as s (s)}<option value={s}>{s} side</option>{/each}</select>
					</label>
				{/if}
			{/if}
		{:else if columns.find((c) => c.id === fill?.col)?.input === 'text'}
			<label>Text <input bind:value={fill.template} /><span class="hint">{'{n}'} is the number</span></label>
		{/if}
		<p class="small muted">First rows: {fillItems().slice(0, 4).map((it) => (typeof it.value === 'object' ? (it.value as { house_number: string }).house_number : it.value)).join(', ')}{targetRows().length > 4 ? '…' : ''}</p>
		<div class="spread">
			<span class="muted small">{mode === 'starting' ? `Starting ${year}` : `Seen in ${year}`} · previewed before anything changes</span>
			<span class="row"><button class="ghost" onclick={() => (fill = null)}>Cancel</button><button class="primary" onclick={previewFill} disabled={!editing}>Preview</button></span>
		</div>
	</div>
{/if}

{#if del}
	<div class="backdrop" role="presentation" onclick={() => (del = null)}></div>
	<div class="dialog" role="dialog" aria-modal="true" aria-label="Delete pages">
		<h2>Delete {sel.size} page{sel.size === 1 ? '' : 's'}?</h2>
		<p class="small">Their facts, shapes, articles, links and the sources made for them go too. It's kept in the change set: undo it from here, or later from the set's review page.</p>
		{#if rows.some((r) => sel.has(r.id) && r.spaces)}
			<label class="check"><input type="checkbox" bind:checked={del.spaces} /> Also delete the spaces inside them</label>
		{/if}
		<label>Type <strong>{sel.size}</strong> to confirm <input inputmode="numeric" bind:value={del.typed} /></label>
		<div class="spread">
			<span></span>
			<span class="row"><button class="ghost" onclick={() => (del = null)}>Cancel</button><button class="primary danger-bg" disabled={Number(del.typed) !== sel.size || deleting} onclick={doDelete}>{deleting ? 'Deleting…' : `Delete ${sel.size}`}</button></span>
		</div>
	</div>
{/if}

<style>
	.context {
		border: 1px solid var(--line);
		border-radius: var(--radius);
		background: var(--bg-2);
		padding: 10px 12px;
		margin-bottom: 12px;
	}
	.ctx-summary {
		width: 100%;
		justify-content: flex-start;
		flex-wrap: wrap;
		background: none;
		border: 0;
		padding: 0;
		text-align: left;
	}
	.ctx-form[hidden] {
		display: none;
	}
	.context.live {
		border-color: var(--rust);
		box-shadow: inset 3px 0 0 var(--rust);
	}
	.ctx-form {
		display: flex;
		flex-wrap: wrap;
		gap: 8px 12px;
		align-items: flex-end;
	}
	.f {
		display: flex;
		flex-direction: column;
		gap: 3px;
		margin: 0;
	}
	.f > span {
		font-size: 0.74rem;
		color: var(--muted);
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}
	.f.year input {
		width: 9ch;
	}
	.f.src {
		flex: 1 1 260px;
		min-width: 220px;
	}
	.f.detail input {
		width: 16ch;
	}
	.f.conf select {
		width: auto;
	}
	.f.actions {
		flex-direction: row;
		gap: 6px;
	}
	.newsrc {
		flex-basis: 100%;
	}
	.pills {
		display: flex;
		gap: 3px;
	}
	.pill {
		display: inline-flex;
		align-items: center;
		padding: 5px 10px;
		border: 1px solid var(--line-2);
		border-radius: 999px;
		font-size: 0.82rem;
		cursor: pointer;
		margin: 0;
		color: var(--ink-2);
	}
	.pill input {
		position: absolute;
		opacity: 0;
		pointer-events: none;
	}
	.pill.on {
		background: var(--rust);
		border-color: var(--rust);
		color: #fff;
	}
	.pill:focus-within {
		outline: 2px solid var(--sky);
	}
	.set-line {
		display: flex;
		flex-wrap: wrap;
		gap: 6px 14px;
		align-items: center;
		margin-top: 8px;
	}
	.set-line form {
		display: inline;
	}
	.switch select {
		width: auto;
		padding: 3px 6px;
		font-size: 0.82rem;
	}
	.linkish {
		background: none;
		border: 0;
		padding: 0;
		color: var(--sky);
		cursor: pointer;
		font: inherit;
	}
	.linkish:hover {
		text-decoration: underline;
	}
	.danger-text {
		color: var(--danger);
	}
	.danger-bg {
		background: var(--danger);
		border-color: var(--danger);
	}
	.filters {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		align-items: center;
	}
	.filters .q input {
		width: 26ch;
	}
	.filters select {
		width: auto;
	}
	.inside {
		width: 220px;
	}
	.grow {
		flex: 1;
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
	.cols {
		position: relative;
	}
	.cols summary {
		list-style: none;
	}
	.col-menu {
		position: absolute;
		right: 0;
		top: calc(100% + 4px);
		z-index: 40;
		display: flex;
		gap: 18px;
		background: var(--panel);
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		padding: 10px 12px;
		max-height: 60vh;
		overflow: auto;
		box-shadow: 0 10px 30px rgba(0, 0, 0, 0.4);
	}
	.col-group {
		min-width: 150px;
	}
	.check {
		display: flex;
		gap: 6px;
		align-items: center;
		font-size: 0.88rem;
		margin: 2px 0;
		white-space: nowrap;
	}
	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		margin-top: 8px;
		align-items: center;
	}
	.chip {
		padding: 3px 10px;
		border-radius: 999px;
		font-size: 0.82rem;
		background: var(--panel-2);
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
	.bulkbar button {
		padding: 5px 10px;
	}
	.grid-wrap {
		position: relative;
		overflow: auto;
		max-height: calc(100vh - 160px);
		border: 1px solid var(--line);
		border-radius: var(--radius);
		outline: none;
	}
	.grid-wrap:focus-visible {
		border-color: var(--sky);
	}
	table {
		border-collapse: separate;
		border-spacing: 0;
		width: max-content;
		min-width: 100%;
		font-size: 0.88rem;
	}
	th {
		position: sticky;
		top: 0;
		z-index: 2;
		background: var(--panel);
		text-align: left;
		font-weight: 600;
		padding: 7px 8px;
		border-bottom: 1px solid var(--line-2);
		white-space: nowrap;
	}
	th .x {
		padding: 0 4px;
		margin-left: 4px;
		border: 0;
		background: none;
		color: var(--muted);
		visibility: hidden;
	}
	th:hover .x {
		visibility: visible;
	}
	th.ro,
	td.ro {
		color: var(--ink-2);
	}
	td {
		padding: 5px 8px;
		border-bottom: 1px solid var(--line);
		vertical-align: top;
		max-width: 340px;
		cursor: default;
	}
	td.focus {
		outline: 2px solid var(--sky);
		outline-offset: -2px;
		background: rgba(143, 179, 201, 0.06);
	}
	.tick {
		width: 28px;
		position: sticky;
		left: 0;
		background: var(--bg);
		z-index: 1;
	}
	th.tick {
		z-index: 3;
		background: var(--panel);
	}
	.pagecol {
		position: sticky;
		left: 28px;
		background: var(--bg);
		z-index: 1;
		min-width: 200px;
		max-width: 280px;
		border-right: 1px solid var(--line);
	}
	th.pagecol {
		z-index: 3;
		background: var(--panel);
	}
	tr.selected td {
		background: rgba(194, 86, 43, 0.1);
	}
	tr.selected td.tick,
	tr.selected td.pagecol {
		background: #2a1d16;
	}
	tr.absent .pagecol a {
		color: var(--muted);
	}
	.meta {
		display: block;
		font-size: 0.74rem;
		color: var(--muted);
	}
	.fact {
		display: block;
	}
	.fact.multi {
		display: inline-block;
		border: 1px solid var(--line-2);
		border-radius: 999px;
		padding: 0 8px;
		margin: 1px 3px 1px 0;
	}
	.cite {
		margin-left: 4px;
		font-size: 0.6rem;
		color: var(--moss);
		vertical-align: 1px;
	}
	.cite.none {
		color: var(--amber);
	}
	.implicit {
		color: var(--muted);
		font-style: italic;
	}
	.empty {
		color: var(--line-2);
	}
	.plain {
		display: block;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.none {
		padding: 30px;
		text-align: center;
	}
	.editor-at {
		position: absolute;
		z-index: 30;
	}
	.pager {
		display: flex;
		gap: 10px;
		align-items: center;
		flex-wrap: wrap;
		margin-top: 8px;
	}
	.toast {
		position: fixed;
		z-index: 70;
		bottom: 18px;
		left: 50%;
		transform: translateX(-50%);
		max-width: min(820px, calc(100vw - 32px));
		display: flex;
		gap: 8px;
		align-items: center;
		flex-wrap: wrap;
		padding: 9px 12px;
		border-radius: var(--radius);
		background: var(--panel);
		border: 1px solid var(--line-2);
		box-shadow: 0 8px 26px rgba(0, 0, 0, 0.5);
		font-size: 0.9rem;
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
	.toast button {
		padding: 3px 9px;
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
		top: 10vh;
		transform: translateX(-50%);
		width: min(540px, calc(100vw - 32px));
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
	.lbl {
		display: block;
		font-size: 0.82rem;
		margin-bottom: 4px;
	}
	@media (max-width: 700px) {
		.filters .q input,
		.inside {
			width: 100%;
		}
		.filters .q {
			flex-basis: 100%;
		}
		.grid-wrap {
			max-height: none;
		}
	}
</style>
