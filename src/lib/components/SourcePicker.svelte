<script lang="ts">
	import { untrack } from 'svelte';
	import { NEW_SOURCE, type SourceOption } from '$lib/sources';
	import { formatFuzzy } from '$lib/time';

	/**
	 * Searchable source picker: type any part of a source's title, author,
	 * publisher, kind, year or website. This page's own sources come first.
	 * The value is a source id, NEW_SOURCE ("make one for this page") or '' (none).
	 */
	let {
		value = $bindable(''),
		sources = [],
		name = undefined,
		id = undefined,
		allowNone = true,
		noneLabel = 'Uncited',
		allowNew = true,
		newLabel = 'New source for this page…',
		placeholder = 'Search sources…',
		resetValue = undefined
	}: {
		value?: string;
		sources?: SourceOption[];
		/** submit the value as this form field */
		name?: string;
		id?: string;
		allowNone?: boolean;
		noneLabel?: string;
		allowNew?: boolean;
		newLabel?: string;
		placeholder?: string;
		/** value to go back to when the enclosing form is reset (default: the first value) */
		resetValue?: string;
	} = $props();

	type Item =
		| { type: 'none' | 'new' | 'unlisted'; key: string; value: string }
		| { type: 'source'; key: string; value: string; s: SourceOption; score: number };

	const LIMIT = 60;
	const initial = untrack(() => value);
	const listId = $derived(`${id ?? name ?? 'src'}-options`);

	let q = $state('');
	let open = $state(false);
	let active = $state(0);
	let input: HTMLInputElement | undefined = $state();
	let list: HTMLUListElement | undefined = $state();

	const host = (u?: string | null) => {
		if (!u) return '';
		try {
			return new URL(u).hostname.replace(/^www\./, '');
		} catch {
			return '';
		}
	};
	const when = (s: SourceOption) => (s.published_on ? formatFuzzy(s.published_on, s.published_precision ?? 'year') : '');
	const kindLabel = (k?: string | null) => (k && k !== 'other' ? k.replace('_', ' ') : '');
	/** "newspaper · Gary Post-Tribune · May 1926 · newspapers.com" */
	const meta = (s: SourceOption) => [kindLabel(s.kind), s.author, s.publisher, when(s), host(s.url)].filter(Boolean).join(' · ');

	const byId = $derived(new Map(sources.map((s) => [s.id, s])));
	const current = $derived(byId.get(value));
	const unlisted = $derived(!!value && value !== NEW_SOURCE && !current);
	const shown = $derived(
		value === NEW_SOURCE ? newLabel : current ? current.title : unlisted ? 'Current source (from another page)' : allowNone ? noneLabel : ''
	);

	const hay = $derived(new Map(sources.map((s) => [s.id, `${s.title} ${meta(s)}`.toLowerCase()])));
	const terms = $derived(q.trim().toLowerCase().split(/\s+/).filter(Boolean));
	/** All sources matching every typed word, best first: title starts with it, title has it, anything else; this page's first. */
	const matches = $derived.by(() => {
		const t = terms;
		const phrase = t.join(' ');
		const out: { s: SourceOption; score: number }[] = [];
		for (const s of sources) {
			const h = hay.get(s.id) ?? '';
			const year = s.published_on?.slice(0, 4) ?? '';
			// "1930s" finds anything published 1930–39 and "1900s" anything in 1900–99, as the date fields read them
			// ("2000s" is the decade); plus plain text matches
			const century = (w: string) => w.endsWith('00s') && !w.startsWith('20');
			const hit = (w: string) => h.includes(w) || (!!year && /^\d{3}0s$/.test(w) && year.startsWith(w.slice(0, century(w) ? 2 : 3)));
			if (!t.every(hit)) continue;
			const title = s.title.toLowerCase();
			const score = !t.length ? 0 : title.startsWith(phrase) ? 0 : t.every((w) => title.includes(w)) ? 1 : 2;
			out.push({ s, score });
		}
		return out.sort(
			(a, b) => a.score - b.score || Number(!a.s.entity_id) - Number(!b.s.entity_id) || a.s.title.localeCompare(b.s.title, undefined, { numeric: true, sensitivity: 'base' })
		);
	});
	const items = $derived.by((): Item[] => {
		const out: Item[] = [];
		if (!terms.length) {
			if (allowNone) out.push({ type: 'none', key: 'none', value: '' });
			if (unlisted) out.push({ type: 'unlisted', key: 'unlisted', value });
		}
		const top = matches.slice(0, LIMIT);
		// a long library can push the current choice past the cut-off; keep it in view (last before the hint)
		if (!terms.length && current && !top.some((m) => m.s.id === current.id)) {
			const m = matches.find((x) => x.s.id === current.id);
			if (m) top.splice(LIMIT - 1, 1, m);
		}
		for (const m of top) out.push({ type: 'source', key: m.s.id, value: m.s.id, s: m.s, score: m.score });
		if (allowNew) out.push({ type: 'new', key: 'new', value: NEW_SOURCE });
		return out;
	});
	/** first row of each group gets a heading */
	const heading = (i: number): string | null => {
		const it = items[i];
		if (it.type !== 'source') return null;
		const prev = items[i - 1];
		const group = it.s.entity_id ? 'This page' : 'Library';
		if (terms.length) return i === items.findIndex((x) => x.type === 'source') ? `${matches.length} match${matches.length === 1 ? '' : 'es'}` : null;
		return prev?.type === 'source' && !!prev.s.entity_id === !!it.s.entity_id ? null : group;
	};

	function openList() {
		if (open) return;
		open = true;
		q = '';
		active = Math.max(0, items.findIndex((it) => it.value === value));
		queueMicrotask(scrollActive);
	}
	function close() {
		open = false;
		q = '';
	}
	function choose(it: Item) {
		value = it.value;
		close();
	}
	function scrollActive() {
		list?.querySelector<HTMLElement>(`[data-i="${active}"]`)?.scrollIntoView({ block: 'nearest' });
	}
	function move(d: number) {
		if (!items.length) return;
		active = (active + d + items.length) % items.length;
		scrollActive();
	}
	function key(e: KeyboardEvent) {
		if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
			e.preventDefault();
			if (!open) return openList();
			move(e.key === 'ArrowDown' ? 1 : -1);
		} else if (e.key === 'Enter') {
			e.preventDefault(); // never submit the form from here
			if (open && items[active]) choose(items[active]);
			else openList();
		} else if (e.key === 'Escape' && open) {
			e.preventDefault();
			close();
		} else if (e.key === 'Tab') close();
	}

	// Go back to the saved value when the enclosing form is reset after a save
	$effect(() => {
		const f = input?.form;
		if (!f) return;
		const onreset = () => queueMicrotask(() => (value = resetValue ?? initial));
		f.addEventListener('reset', onreset);
		return () => f.removeEventListener('reset', onreset);
	});
</script>

<div class="source-picker" class:open>
	<input
		{id}
		bind:this={input}
		type="text"
		role="combobox"
		autocomplete="off"
		aria-expanded={open}
		aria-controls={listId}
		aria-activedescendant={open && items[active] ? `${listId}-${active}` : undefined}
		value={open ? q : shown}
		placeholder={open ? (shown && shown !== noneLabel ? shown : placeholder) : placeholder}
		title={current ? `${current.title}${meta(current) ? `\n${meta(current)}` : ''}` : undefined}
		class:chosen={!!current || value === NEW_SOURCE}
		onfocus={openList}
		onclick={openList}
		oninput={(e) => {
			q = e.currentTarget.value;
			open = true;
			active = items.findIndex((it) => it.type === 'source');
			if (active < 0) active = 0;
		}}
		onkeydown={key}
		onblur={close}
	/>
	{#if current && !open && meta(current)}<div class="current-meta">{meta(current)}</div>{/if}
	{#if name}<input type="hidden" {name} {value} />{/if}
	{#if open}
		<!-- mousedown is prevented so the input keeps focus (and the list stays open) while choosing -->
		<ul id={listId} role="listbox" bind:this={list} onmousedown={(e) => e.preventDefault()}>
			{#each items as it, i (it.key)}
				{@const h = heading(i)}
				{#if h}<li class="group" role="presentation">{h}</li>{/if}
				<!-- keyboard choice goes through the input (arrows + Enter, aria-activedescendant) -->
				<!-- svelte-ignore a11y_click_events_have_key_events -->
				<li
					id="{listId}-{i}"
					data-i={i}
					role="option"
					aria-selected={i === active}
					class:active={i === active}
					class:picked={it.value === value}
					class={it.type}
					onclick={() => choose(it)}
					onmousemove={() => (active = i)}
				>
					{#if it.type === 'source'}
						<span class="title">{it.s.title}</span>
						{#if it.s.entity_id && terms.length}<span class="tag">this page</span>{/if}
						{#if meta(it.s)}<span class="meta">{meta(it.s)}</span>{/if}
					{:else if it.type === 'new'}
						<span class="title">+ {newLabel}</span>
						{#if terms.length}<span class="meta">Nothing right? Make a source just for this page.</span>{/if}
					{:else if it.type === 'unlisted'}
						<span class="title">Current source (from another page)</span>
						<span class="meta">Kept as it is; it isn't offered on this page.</span>
					{:else}
						<span class="title">{noneLabel}</span>
					{/if}
				</li>
			{/each}
			{#if matches.length > LIMIT}
				<li class="more" role="presentation">Showing {LIMIT} of {matches.length}. Type more to narrow it down.</li>
			{:else if terms.length && !matches.length}
				<li class="more" role="presentation">No source matches “{q.trim()}”.</li>
			{/if}
		</ul>
	{/if}
</div>

<style>
	.source-picker {
		position: relative;
	}
	input {
		width: 100%;
		text-overflow: ellipsis;
	}
	input.chosen {
		border-color: var(--moss);
	}
	.current-meta {
		margin-top: 2px;
		font-size: 0.72rem;
		color: var(--muted);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	ul {
		position: absolute;
		z-index: 40;
		left: 0;
		top: calc(100% + 2px);
		width: max(100%, min(520px, 90vw));
		max-height: 340px;
		overflow-y: auto;
		margin: 0;
		padding: 4px;
		list-style: none;
		background: var(--panel-2);
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
	}
	li[role='option'] {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		gap: 0 8px;
		padding: 6px 8px;
		border-radius: calc(var(--radius) - 2px);
		cursor: pointer;
	}
	li.active {
		background: var(--line);
	}
	li.picked .title::after {
		content: ' ✓';
		color: var(--moss);
	}
	.title {
		min-width: 0;
		overflow-wrap: anywhere;
	}
	.meta {
		flex-basis: 100%;
		font-size: 0.75rem;
		color: var(--muted);
	}
	.tag {
		font-size: 0.68rem;
		padding: 0 6px;
		border: 1px solid var(--line-2);
		border-radius: 999px;
		color: var(--muted);
	}
	li.none .title,
	li.unlisted .title {
		color: var(--muted);
		font-style: italic;
	}
	li.new {
		border-top: 1px solid var(--line);
		margin-top: 4px;
	}
	li.new .title {
		color: var(--moss);
	}
	.group {
		padding: 8px 8px 2px;
		font-size: 0.68rem;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--muted);
	}
	.more {
		padding: 6px 8px;
		font-size: 0.75rem;
		color: var(--muted);
	}
</style>
