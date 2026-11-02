<script lang="ts">
	import type { SearchHit } from '$lib/types';
	import { yearOf } from '$lib/time';

	let {
		name,
		kinds = null,
		value = null,
		values = null,
		multiple = false,
		placeholder = 'Search for a page…',
		required = false,
		id = undefined
	}: {
		name: string;
		kinds?: string[] | null;
		value?: { id: string; name: string } | null;
		/** initial selection when `multiple` is set */
		values?: { id: string; name: string }[] | null;
		/** allow several pages; one hidden input per pick is submitted */
		multiple?: boolean;
		placeholder?: string;
		required?: boolean;
		id?: string;
	} = $props();

	let picked = $state<{ id: string; name: string } | null>(null);
	let chosen = $state<{ id: string; name: string }[]>([]);
	let seeded = false;
	let q = $state('');
	$effect.pre(() => {
		if (multiple) {
			// Seed once, so a re-render never discards picks the user just made.
			if (!seeded) {
				chosen = values ?? [];
				seeded = true;
			}
			return;
		}
		picked = value;
		q = value?.name ?? '';
	});
	let hits = $state<SearchHit[]>([]);
	let open = $state(false);
	let active = $state(0);
	let timer: ReturnType<typeof setTimeout> | undefined;

	function search() {
		clearTimeout(timer);
		if (!multiple) picked = null;
		timer = setTimeout(async () => {
			if (q.trim().length < 2) return void (hits = []);
			const params = new URLSearchParams({ q });
			if (kinds?.length) params.set('kinds', kinds.join(','));
			const res = await fetch(`/api/search?${params}`);
			const found: SearchHit[] = res.ok ? await res.json() : [];
			hits = found.filter((h) => !chosen.some((c) => c.id === h.id));
			open = true;
			active = 0;
		}, 160);
	}
	function choose(h: SearchHit) {
		if (multiple) {
			if (!chosen.some((c) => c.id === h.id)) chosen = [...chosen, { id: h.id, name: h.name }];
			q = '';
			hits = [];
			open = false;
			return;
		}
		picked = { id: h.id, name: h.name };
		q = h.name;
		open = false;
	}
	function remove(target: { id: string }) {
		chosen = chosen.filter((c) => c.id !== target.id);
	}
	function key(e: KeyboardEvent) {
		if (!open || !hits.length) return;
		if (e.key === 'ArrowDown') active = (active + 1) % hits.length;
		else if (e.key === 'ArrowUp') active = (active - 1 + hits.length) % hits.length;
		else if (e.key === 'Enter') {
			e.preventDefault();
			choose(hits[active]);
		} else if (e.key === 'Escape') open = false;
		else return;
		e.preventDefault();
	}
</script>

<div class="picker">
	{#if multiple && chosen.length}
		<ul class="chosen" aria-label="Selected pages">
			{#each chosen as c (c.id)}
				<li>
					<span>{c.name}</span>
					<button type="button" class="remove" aria-label="Remove {c.name}" onclick={() => remove(c)}>×</button>
				</li>
			{/each}
		</ul>
	{/if}
	<input
		{id}
		type="text"
		bind:value={q}
		oninput={search}
		onkeydown={key}
		onfocus={() => hits.length && (open = true)}
		onblur={() => setTimeout(() => (open = false), 150)}
		{placeholder}
		autocomplete="off"
		class:ok={multiple ? chosen.length > 0 : !!picked}
		role="combobox"
		aria-expanded={open}
		aria-controls="{name}-list"
	/>
	{#if multiple}
		{#each chosen as c (c.id)}<input type="hidden" {name} value={c.id} />{/each}
	{:else}
		<input type="hidden" {name} value={picked?.id ?? ''} {required} />
	{/if}
	{#if open && hits.length}
		<ul id="{name}-list" role="listbox">
			{#each hits as h, i (h.id)}
				<li role="option" aria-selected={i === active}>
					<button type="button" class:active={i === active} onmousedown={() => choose(h)}>
						<span>{h.name}</span>
						{#if h.matched_name !== h.name}<span class="muted small">“{h.matched_name}”</span>{/if}
						<span class="meta">{h.kind}{h.exists_from ? ` · ${yearOf(h.exists_from)}` : ''}</span>
					</button>
				</li>
			{/each}
		</ul>
	{:else if open && q.length >= 2}
		<ul><li class="muted small empty">No match. <a href="/new" target="_blank">Create the page</a> first.</li></ul>
	{/if}
</div>

<style>
	.picker {
		position: relative;
	}
	input.ok {
		border-color: var(--moss);
	}
	ul:not(.chosen) {
		position: absolute;
		z-index: 30;
		left: 0;
		right: 0;
		top: calc(100% + 2px);
		margin: 0;
		padding: 4px;
		list-style: none;
		background: var(--panel-2);
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		max-height: 280px;
		overflow-y: auto;
		box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
	}
	.chosen {
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
		margin: 0 0 6px;
		padding: 0;
		list-style: none;
	}
	.chosen li {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		padding: 2px 4px 2px 8px;
		background: var(--panel-2);
		border: 1px solid var(--line-2);
		border-radius: 999px;
		font-size: 0.82rem;
	}
	.remove {
		width: 18px;
		height: 18px;
		padding: 0;
		line-height: 1;
		border: 0;
		border-radius: 50%;
		background: transparent;
		color: var(--muted);
	}
	.remove:hover {
		background: var(--line);
		color: var(--ink);
	}
	button {
		width: 100%;
		display: flex;
		gap: 8px;
		align-items: baseline;
		border: 0;
		background: transparent;
		padding: 6px 8px;
		text-align: left;
	}
	button.active,
	button:hover {
		background: var(--line);
	}
	.meta {
		margin-left: auto;
		font-size: 0.75rem;
		color: var(--muted);
	}
	.empty {
		padding: 6px 8px;
	}
</style>
