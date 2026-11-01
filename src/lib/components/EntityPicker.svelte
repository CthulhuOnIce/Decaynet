<script lang="ts">
	import type { SearchHit } from '$lib/types';
	import { yearOf } from '$lib/time';

	let {
		name,
		kinds = null,
		value = null,
		placeholder = 'Search for a page…',
		required = false,
		id = undefined
	}: {
		name: string;
		kinds?: string[] | null;
		value?: { id: string; name: string } | null;
		placeholder?: string;
		required?: boolean;
		id?: string;
	} = $props();

	let picked = $state<{ id: string; name: string } | null>(null);
	let q = $state('');
	$effect.pre(() => {
		picked = value;
		q = value?.name ?? '';
	});
	let hits = $state<SearchHit[]>([]);
	let open = $state(false);
	let active = $state(0);
	let timer: ReturnType<typeof setTimeout> | undefined;

	function search() {
		clearTimeout(timer);
		picked = null;
		timer = setTimeout(async () => {
			if (q.trim().length < 2) return void (hits = []);
			const params = new URLSearchParams({ q });
			if (kinds?.length) params.set('kinds', kinds.join(','));
			const res = await fetch(`/api/search?${params}`);
			hits = res.ok ? await res.json() : [];
			open = true;
			active = 0;
		}, 160);
	}
	function choose(h: SearchHit) {
		picked = { id: h.id, name: h.name };
		q = h.name;
		open = false;
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
		class:ok={!!picked}
		role="combobox"
		aria-expanded={open}
		aria-controls="{name}-list"
	/>
	<input type="hidden" {name} value={picked?.id ?? ''} {required} />
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
	ul {
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
