<script lang="ts">
	import { enhance } from '$app/forms';
	import { goto } from '$app/navigation';

	let { data, form } = $props();
	const e = $derived(data.entity);
	const p = $derived(data.preview && !data.preview.blocked ? data.preview : null);
	const kinds = $derived(data.vocab.kinds.filter((k) => k.id !== e.kind && k.id !== 'media'));
	const chosen = $derived(data.to !== e.kind ? data.vocab.kinds.find((k) => k.id === data.to) : null);

	/** "2 names, 1 tag" style counts for a list of items */
	function counts(items: { what: string }[]) {
		const m = new Map<string, number>();
		for (const i of items) m.set(i.what, (m.get(i.what) ?? 0) + 1);
		return [...m.entries()].map(([w, n]) => `${n} ${n === 1 ? w : w === 'address' ? 'addresses' : `${w}s`}`).join(', ');
	}
	const an = (w: string) => `${/^[aeiou]/i.test(w) ? 'an' : 'a'} ${w.toLowerCase()}`;
	const WHY: Record<string, (to: string, from: string) => string> = {
		place: (to, from) => `Stays with the ${from.toLowerCase()}: the new ${to.toLowerCase()} is linked to it instead`,
		kind: (to) => `Doesn't fit ${an(to)}`,
		unique: () => 'Map and Wikidata ids stay with the original: one page per id'
	};
	const groups = $derived(
		p ? (['place', 'kind', 'unique'] as const).map((why) => ({ why, items: p.left.filter((i) => i.why === why) })).filter((g) => g.items.length) : []
	);
	let busy = $state(false);
	let newName = $state('');
	$effect.pre(() => {
		newName = p?.name ?? '';
	});
</script>

<svelte:head><title>Duplicate · {e.name}</title></svelte:head>

<div class="page narrow">
	<div class="eyebrow">Duplicate</div>
	<h1><a href="/e/{e.slug}">{e.name}</a></h1>
	<p class="muted">
		Makes a <strong>new page</strong> next to this one and copies everything that fits; <strong>this page isn't changed</strong>.
		An exact copy splits a page that holds two things, like a building demolished and another built on the same spot. Another
		kind fixes a page created as the wrong thing, like a “building” that is really the business inside it.
	</p>

	<form method="get" class="row pick">
		<label for="to">Copy as</label>
		<select id="to" name="to" onchange={(ev) => goto(`?to=${(ev.currentTarget as HTMLSelectElement).value}`, { noScroll: true, keepFocus: true })}>
			<option value={e.kind} selected={data.to === e.kind}>Same kind: exact copy</option>
			<optgroup label="Another kind">
				{#each kinds as k (k.id)}<option value={k.id} selected={data.to === k.id}>{k.label}</option>{/each}
			</optgroup>
		</select>
		<noscript><button>Preview</button></noscript>
	</form>
	{#if chosen?.description}<p class="hint">{chosen.description}</p>{/if}

	{#if data.preview?.blocked}
		<p class="notice error">{data.preview.blocked}</p>
	{:else if p}
		{#if form?.error}<p class="notice error">{form.error}</p>{/if}
		<form
			method="post"
			action="?/duplicate"
			class="stack"
			use:enhance={() => {
				busy = true;
				return async ({ update }) => {
					await update();
					busy = false;
				};
			}}
		>
			<input type="hidden" name="kind" value={p.to} />
			<section class="card stack">
				<h2>{p.same ? 'The copy' : `The new ${p.to_label.toLowerCase()}`}</h2>
				<div><label for="name">Name</label><input id="name" name="name" bind:value={newName} required /></div>
				{#if p.tie}
					<p class="tie">
						{#if p.tie.copy_is_subject}
							It will be linked to this page: <strong>{newName || p.name}</strong> {p.tie.reading} <strong>{e.name}</strong>, over its lifespan.
						{:else}
							This page will be linked to it: <strong>{e.name}</strong> {p.tie.reading} the new {p.to_label.toLowerCase()}, over its lifespan.
						{/if}
					</p>
				{/if}
				<div>
					<h3>Copied</h3>
					<p class="small">
						Name, summary, lifespan and privacy{#if p.copied.length}; {counts(p.copied)}{/if}{#if p.article}; the article, as its first revision{/if}{#if p.sources};
							{p.sources} source{p.sources === 1 ? '' : 's'} made for this page (citations point at the copies){/if}.
						{#if p.event && !p.same}It gets an event type of “Other” to change afterwards.{/if}
					</p>
					{#if p.same}
						<p class="small hint">
							Splitting two buildings? Afterwards, remove the second building's facts from this page and the first one's from the
							copy, give each its own dates, then run <em>Clean up timeline</em> on both.
						</p>
					{/if}
					{#if p.copied.length}
						<details>
							<summary class="small">Show {p.copied.length} item{p.copied.length === 1 ? '' : 's'}</summary>
							<ul class="plain-list small">{#each p.copied as i, n (n)}<li><span class="muted">{i.what}</span> {i.label}</li>{/each}</ul>
						</details>
					{/if}
				</div>
				{#if groups.length}
					<div>
						<h3>Left with the original</h3>
						{#each groups as g (g.why)}
							<p class="small"><strong>{WHY[g.why](p.to_label, p.from_label)}:</strong> {g.items.map((i) => i.label).join('; ')}</p>
						{/each}
					</div>
				{/if}
			</section>
			<div class="row">
				<button class="primary" disabled={busy}>{busy ? 'Creating…' : p.same ? 'Create the copy' : `Create the ${p.to_label.toLowerCase()}`}</button>
				<a class="btn ghost" href="/e/{e.slug}">Cancel</a>
			</div>
		</form>
	{/if}
</div>

<style>
	.pick {
		align-items: center;
		gap: 10px;
		margin-top: 14px;
	}
	.pick label {
		margin: 0;
	}
	.pick select {
		max-width: 260px;
	}
	h3 {
		margin: 4px 0;
		font-size: 0.95rem;
	}
	.tie {
		margin: 0;
		padding: 8px 10px;
		border-left: 3px solid var(--amber);
		background: var(--bg);
	}
	details ul {
		margin: 6px 0 0;
	}
	details li {
		padding: 2px 0;
	}
</style>
