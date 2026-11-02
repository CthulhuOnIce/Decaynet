<script lang="ts">
	import type { EntitySnapshot } from '$lib/types';
	import { formatFuzzy, formatRange } from '$lib/time';
	import { isImage, mediaSrc } from '$lib/media';
	import Badge from './Badge.svelte';
	import KindBadge from './KindBadge.svelte';

	let {
		snap,
		year,
		loading = false,
		onclose,
		onpick
	}: {
		snap: EntitySnapshot | null;
		year: number;
		loading?: boolean;
		onclose: () => void;
		onpick: (id: string) => void;
	} = $props();

	const phaseNote = $derived.by(() => {
		if (!snap) return null;
		if (snap.phase === 'future')
			return `Not here yet in ${year}. ${snap.kind_label} dates from ${formatFuzzy(snap.exists_from, snap.exists_from_precision)}.`;
		if (snap.phase === 'past')
			return `Gone by ${year}. Last recorded ${formatFuzzy(snap.exists_to, snap.exists_to_precision)}.`;
		return null;
	});

	// A place reads as whoever occupies it that year ("Joe's Diner"), its own name underneath
	const occupants = $derived(
		snap && ['building', 'site', 'parcel'].includes(snap.kind) && snap.phase === 'present'
			? snap.relations.filter((r) => r.direction === 'in' && r.predicate === 'occupies')
			: []
	);

	const fmtValue = (v: unknown) => (typeof v === 'number' ? v.toLocaleString() : String(v));
	const qual = (q: Record<string, unknown>) => {
		const vals = Object.values(q ?? {}).filter((v) => typeof v === 'string');
		return vals.length ? ` (${vals.join(', ')})` : '';
	};
</script>

<aside class="panel" aria-label="Selected place">
	<button class="close icon-btn ghost" onclick={onclose} aria-label="Close">✕</button>

	{#if loading && !snap}
		<p class="muted">Loading…</p>
	{:else if snap}
		<div class="eyebrow">As of {year}</div>
		{#if occupants.length}
			<h2 class="occupant">
				{#each occupants as o, i (o.id)}{i ? ' · ' : ''}<button class="link" onclick={() => onpick(o.id)} title="Open {o.name}">{o.name}</button>{/each}
			</h2>
			<div class="place-name">in {snap.name}</div>
		{:else}
			<h2>{snap.name}</h2>
		{/if}
		{#if snap.name !== snap.canonical_name}
			<div class="muted small">Today's page: {snap.canonical_name}</div>
		{/if}

		<div class="row badges">
			<KindBadge kind={snap.kind} />
			{#if snap.status}
				<Badge color={snap.status.color} label={snap.status.label} />
			{/if}
			<span class="date">{formatRange(snap.exists_from, snap.exists_from_precision, snap.exists_to, snap.exists_to_precision)}</span>
		</div>

		{#if phaseNote}<p class="notice">{phaseNote}</p>{/if}
		{#if snap.address}<p class="addr">📍 {snap.address}</p>{/if}
		{#if snap.summary}<p class="summary">{snap.summary}</p>{/if}

		{#if snap.media.length}
			<div class="media">
				{#each snap.media.slice(0, 4) as m (m.id)}
					{@const src = mediaSrc(m.storage_path, m.external_url)}
					<a href="/e/{m.slug}" title="{m.name} ({formatFuzzy(m.captured, m.captured_precision)})">
						{#if src && isImage(m.media_type)}
							<img {src} alt={m.name} loading="lazy" />
						{:else}
							<span class="file">{m.media_type}</span>
						{/if}
						<span class="cap">{formatFuzzy(m.captured, m.captured_precision)}</span>
					</a>
				{/each}
			</div>
		{/if}

		{#if snap.attributes.length}
			<table class="attrs">
				<tbody>
					{#each snap.attributes as a (a.key)}
						<tr>
							<th>{a.label}</th>
							<td>{fmtValue(a.value)}{a.unit ? ` ${a.unit}` : ''}</td>
						</tr>
					{/each}
				</tbody>
			</table>
		{/if}

		{#if snap.relations.length && snap.phase === 'present'}
			<h3>Connections in {year}</h3>
			<ul class="plain-list rels">
				{#each snap.relations as r, i (i)}
					<li>
						<span class="muted">{r.label}</span>
						<button class="link" onclick={() => onpick(r.id)}>{r.name}</button>{qual(r.qualifiers)}
						{#if r.valid_from || r.valid_to}
							<span class="date">{formatRange(r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision)}</span>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}

		{#if snap.other_names.length > 1 || (snap.other_names.length === 1 && !snap.other_names[0].current)}
			<h3>Names</h3>
			<ul class="plain-list">
				{#each snap.other_names as n, i (i)}
					<li class:current={n.current}>
						{n.name} <span class="muted small">{n.name_type}</span>
						<span class="date">{formatRange(n.valid_from, n.valid_from_precision, n.valid_to, n.valid_to_precision)}</span>
					</li>
				{/each}
			</ul>
		{/if}

		{#if snap.article}
			<h3 class="row">Article <Badge color={snap.article.status_color} label={snap.article.status_label} /></h3>
			{#if snap.article.excerpt.trim()}
				<p class="excerpt">{snap.article.excerpt.trim().slice(0, 300)}{snap.article.excerpt.length > 300 ? '…' : ''}</p>
			{:else}
				<p class="muted small">No article yet. This is a stub waiting for a writer.</p>
			{/if}
		{/if}

		<div class="row actions">
			<a class="btn primary" href="/e/{snap.slug}?y={year}">Open page</a>
			<a class="btn" href="/e/{snap.slug}#timeline">Timeline</a>
		</div>
	{/if}
</aside>

<style>
	h2.occupant {
		margin-bottom: 0;
	}
	h2.occupant .link {
		background: none;
		border: 0;
		padding: 0;
		font: inherit;
		color: inherit;
		cursor: pointer;
		text-align: left;
	}
	h2.occupant .link:hover {
		text-decoration: underline;
	}
	.place-name {
		margin: 2px 0 4px;
		color: var(--ink-2);
		font-size: 0.9rem;
	}
	.panel {
		position: relative;
		height: 100%;
		overflow-y: auto;
		padding: 18px 18px 28px;
		background: rgba(27, 23, 20, 0.97);
		border-left: 1px solid var(--line);
	}
	.close {
		position: absolute;
		top: 10px;
		right: 10px;
		border: 0;
	}
	h2 {
		margin: 4px 30px 4px 0;
		font-size: 1.5rem;
	}
	h3 {
		margin: 18px 0 6px;
		font-size: 0.95rem;
		font-family: var(--sans);
		font-weight: 600;
		gap: 8px;
	}
	.badges {
		margin: 10px 0;
		gap: 6px;
	}
	.addr {
		margin: 8px 0;
		color: var(--ink-2);
	}
	.summary,
	.excerpt {
		color: var(--ink-2);
		font-size: 0.92rem;
	}
	.notice {
		font-size: 0.88rem;
		margin: 10px 0;
	}
	.attrs th {
		text-transform: none;
		letter-spacing: 0;
		font-size: 0.82rem;
		width: 45%;
	}
	.rels li {
		font-size: 0.9rem;
	}
	.rels .date,
	li .date {
		display: block;
		font-size: 0.75rem;
		color: var(--muted);
	}
	li.current {
		color: var(--amber);
	}
	button.link {
		background: none;
		border: 0;
		padding: 0;
		color: var(--rust-2);
		font: inherit;
		cursor: pointer;
	}
	button.link:hover {
		text-decoration: underline;
	}
	.media {
		display: grid;
		grid-template-columns: repeat(2, 1fr);
		gap: 6px;
		margin: 12px 0;
	}
	.media a {
		position: relative;
		display: block;
		aspect-ratio: 4 / 3;
		background: var(--panel-2);
		border-radius: 4px;
		overflow: hidden;
	}
	.media img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		filter: sepia(0.25);
	}
	.media .file {
		display: grid;
		place-items: center;
		height: 100%;
		color: var(--muted);
		font-size: 0.8rem;
	}
	.media .cap {
		position: absolute;
		left: 4px;
		bottom: 3px;
		font-family: var(--mono);
		font-size: 0.68rem;
		background: rgba(0, 0, 0, 0.6);
		padding: 0 4px;
		border-radius: 3px;
		color: #fff;
	}
	.actions {
		margin-top: 18px;
	}
</style>
