<script lang="ts">
	import { goto } from '$app/navigation';
	import { untrack } from 'svelte';
	import Badge from '$lib/components/Badge.svelte';
	import KindBadge from '$lib/components/KindBadge.svelte';
	import MiniMap from '$lib/components/MiniMap.svelte';
	import Timeline from '$lib/components/Timeline.svelte';
	import ConfidenceMark from '$lib/components/ConfidenceMark.svelte';
	import TagChips from '$lib/components/TagChips.svelte';
	import { formatFuzzy, formatRange } from '$lib/time';
	import { isImage, mediaSrc } from '$lib/media';
	import type { RelationRow } from '$lib/types';

	let { data } = $props();
	const e = $derived(data.entity);
	const snap = $derived(data.snapshot);
	const kind = $derived(data.vocab.kinds.find((k) => k.id === e.kind));

	let yearInput = $state(untrack(() => data.year));
	$effect(() => {
		yearInput = data.year;
	});
	function travel(y: number) {
		goto(`?y=${y}`, { keepFocus: true, noScroll: true, replaceState: true });
	}

	const akas = $derived(snap.other_names.filter((n) => n.name.toLowerCase() !== e.name.toLowerCase()));
	const sourceIndex = $derived(Object.fromEntries(data.sources.map((s, i) => [s.id, i + 1])));

	// Group relations by their reading ("occupied by", "is on", ...), skipping media (gallery shows those)
	const groups = $derived.by(() => {
		const m = new Map<string, RelationRow[]>();
		for (const r of data.relations) {
			if (r.other_kind === 'media') continue;
			const key = r.label;
			if (!m.has(key)) m.set(key, []);
			m.get(key)!.push(r);
		}
		return [...m.entries()];
	});
	const qual = (q: Record<string, unknown>) => {
		const vals = Object.entries(q ?? {}).filter(([, v]) => typeof v === 'string' || typeof v === 'number');
		return vals.length ? vals.map(([k, v]) => `${k}: ${v}`).join(', ') : '';
	};
	const mainMedia = $derived(data.media ? mediaSrc(data.media.storage_path, data.media.external_url) : null);
	const canEdit = $derived(!!data.user && (data.perms ?? []).includes('edit_content'));
	// Footprint (grey) + spaces (highlighted) for the floor-plan minimap
	const floorPlan = $derived<GeoJSON.Feature[]>([
		...data.geomFeatures.filter((f) => f.geometry?.type !== 'Point').map((f) => ({ ...f, properties: { current: false } })),
		...data.spaces.filter((s) => s.geojson && s.present).map((s) => ({ type: 'Feature' as const, geometry: s.geojson!, properties: { current: true } }))
	]);
</script>

<svelte:head><title>{e.name} · Decaynet</title></svelte:head>

<div class="page">
	<header class="head">
		<div class="eyebrow">
			{kind?.label ?? e.kind}
			{#if e.exists_from || e.exists_to}
				· {formatRange(e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision)}
			{/if}
			<ConfidenceMark confidence={e.lifespan_confidence} />
		</div>
		<h1>{e.name}</h1>
		{#if akas.length}
			<p class="aka muted">
				Also recorded as
				{#each akas as n, i (i)}
					{i ? ' · ' : ''}<strong>{n.name}</strong>
					<span class="date">{formatRange(n.valid_from, n.valid_from_precision, n.valid_to, n.valid_to_precision)}</span>
				{/each}
			</p>
		{/if}
		<div class="row">
			<KindBadge kind={e.kind} />
			{#if data.event?.event_types}<Badge color={data.event.event_types.color} label={data.event.event_types.label} />{/if}
			{#if data.article?.article_statuses}
				<Badge color={data.article.article_statuses.color} label="Article: {data.article.article_statuses.label}" title={data.article.article_statuses.description ?? ''} />
			{/if}
			{#if data.article?.locked}<Badge color="#8fb3c9" label="Locked" />{/if}
			<span class="spacer"></span>
			<a class="btn ghost" href="/?y={data.year}&sel={e.id}">View on map</a>
			{#if canEdit}
				<a class="btn" href="/e/{e.slug}/edit">Edit article</a>
				<a class="btn" href="/e/{e.slug}/facts">Edit facts</a>
				<a class="btn ghost" href="/media/new?depicts={e.slug}">+ Media</a>
			{/if}
			<a class="btn ghost" href="/e/{e.slug}/history">History</a>
		</div>
		{#if data.tags.length}
			<div class="tags"><TagChips tags={data.tags} /></div>
		{:else if canEdit}
			<p class="small"><a href="/e/{e.slug}/facts#tags">+ Add tags</a></p>
		{/if}
	</header>

	<div class="grid-2">
		<div class="main">
			{#if mainMedia}
				<figure class="hero">
					{#if data.media && isImage(data.media.media_type)}
						<img src={mainMedia} alt={e.name} />
					{:else if data.media?.media_type === 'video'}
						<!-- svelte-ignore a11y_media_has_caption -->
						<video src={mainMedia} controls></video>
					{:else if data.media?.media_type === 'audio'}
						<audio src={mainMedia} controls></audio>
					{:else}
						<a class="btn" href={mainMedia} target="_blank" rel="noopener">Open file</a>
					{/if}
					<figcaption class="muted small">
						{data.media?.media_type}
						{#if e.exists_from}· captured {formatFuzzy(e.exists_from, e.exists_from_precision)}{/if}
						{#if data.media?.creator}· {data.media.creator}{/if}
						{#if data.media?.rights}· {data.media.rights}{/if}
					</figcaption>
				</figure>
			{/if}

			{#if e.summary}<p class="lede">{e.summary}</p>{/if}

			{#if data.html}
				<article class="prose">{@html data.html}</article>
			{:else}
				<div class="notice">
					This article is a stub. The structured facts below are all we know so far.
					{#if canEdit}<a href="/e/{e.slug}/edit">Write the first draft →</a>{:else}<a href="/login">Sign in to write it →</a>{/if}
				</div>
			{/if}

			{#if data.spaces.length || ['building', 'site'].includes(e.kind)}
				<h2 id="spaces">Spaces & tenants in {data.year}</h2>
				{#if data.spaces.length}
					<div class="spaces">
						<MiniMap features={floorPlan} height={240} />
						<table>
							<thead><tr><th>Space</th><th>Floor</th><th>Tenant in {data.year}</th></tr></thead>
							<tbody>
								{#each data.spaces as sp (sp.id)}
									<tr class:gone={!sp.present}>
										<td><a href="/e/{sp.slug}?y={data.year}">{sp.name}</a>{#if sp.unit_label} <span class="muted small">#{sp.unit_label}</span>{/if}</td>
										<td class="mono">{sp.floor ?? '–'}</td>
										<td>
											{#if !sp.present}<span class="muted">not yet / no longer</span>
											{:else if sp.tenants}{sp.tenants}
											{:else}<span class="muted">vacant / unknown</span>{/if}
										</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				{:else}
					<p class="muted small">
						No spaces mapped inside this {e.kind} yet.
						{#if canEdit}<a href="/e/{e.slug}/facts#spaces">Divide the footprint into storefronts, suites or halls →</a>{/if}
					</p>
				{/if}
			{/if}

			<h2 id="timeline">Timeline</h2>
			<Timeline rows={data.timeline} highlightYear={data.year} {sourceIndex} />

			{#if groups.length}
				<h2>Connections</h2>
				<div class="groups">
					{#each groups as [label, rows] (label)}
						<div class="group">
							<h3>{label.charAt(0).toUpperCase() + label.slice(1)}</h3>
							<ul class="plain-list">
								{#each rows as r (r.id)}
									<li>
										<a href="/e/{r.other_slug}">{r.other_name_then}</a>
										{#if r.other_name_then !== r.other_name}<span class="muted small">(now {r.other_name})</span>{/if}
										{#if qual(r.qualifiers)}<span class="muted small"> · {qual(r.qualifiers)}</span>{/if}
										<ConfidenceMark confidence={r.confidence} />
										{#if r.source_id && sourceIndex[r.source_id]}<sup><a href="#source-{sourceIndex[r.source_id]}">[{sourceIndex[r.source_id]}]</a></sup>{/if}
										<div class="date">{formatRange(r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision) || 'undated'}</div>
									</li>
								{/each}
							</ul>
						</div>
					{/each}
				</div>
			{/if}

			{#if data.gallery.length}
				<h2>Media</h2>
				<div class="gallery">
					{#each data.gallery as g (g.id)}
						{@const mi = Array.isArray(g.media_items) ? g.media_items[0] : g.media_items}
						{@const src = mi ? mediaSrc(mi.storage_path, mi.external_url) : null}
						<a href="/e/{g.slug}" class="tile">
							{#if src && mi && isImage(mi.media_type)}
								<img {src} alt={g.name} loading="lazy" />
							{:else}
								<span class="file">{mi?.media_type ?? 'file'}</span>
							{/if}
							<span class="cap">{formatFuzzy(g.exists_from, g.exists_from_precision)} · {g.name}</span>
						</a>
					{/each}
				</div>
			{/if}

			{#if data.sources.length}
				<h2>Sources</h2>
				<ol class="sources">
					{#each data.sources as s, i (s.id)}
						<li id="source-{i + 1}">
							<a href="/sources/{s.id}">{s.title}</a>
							{#if s.author}, {s.author}{/if}
							{#if s.publisher}. {s.publisher}{/if}
							{#if s.published_on}, {formatFuzzy(s.published_on, s.published_precision)}{/if}
							{#if s.url}· <a href={s.url} target="_blank" rel="noopener">link</a>{/if}
						</li>
					{/each}
				</ol>
			{/if}
		</div>

		<aside class="side stack">
			<div class="card infobox">
				<div class="spread">
					<div class="eyebrow">Snapshot</div>
					<form class="yearform" onsubmit={(ev) => { ev.preventDefault(); travel(yearInput); }}>
						<input type="number" min="1700" max="2100" bind:value={yearInput} aria-label="Year" />
						<button>Go</button>
					</form>
				</div>
				<input
					type="range"
					min={Math.min(1890, Number(e.exists_from?.slice(0, 4) ?? 1890))}
					max={new Date().getFullYear()}
					bind:value={yearInput}
					onchange={() => travel(yearInput)}
					aria-label="Snapshot year"
				/>
				<h3 class="snapname">{snap.name} <span class="muted">in {data.year}</span></h3>
				{#if snap.phase === 'future'}
					<p class="notice small">Doesn't exist yet in {data.year}.</p>
				{:else if snap.phase === 'past'}
					<p class="notice small">Gone by {data.year}.</p>
				{/if}
				<table>
					<tbody>
						{#if snap.status}
							<tr><th>Condition</th><td><Badge color={snap.status.color} label={snap.status.label} /></td></tr>
						{/if}
						{#if snap.address}<tr><th>Address</th><td>{snap.address}</td></tr>{/if}
						{#each snap.attributes as a (a.key)}
							<tr>
								<th>{a.label}</th>
								<td>{typeof a.value === 'number' ? a.value.toLocaleString() : String(a.value)}{a.unit ? ` ${a.unit}` : ''}</td>
							</tr>
						{/each}
						{#each snap.relations.slice(0, 8) as r, i (i)}
							<tr><th>{r.label}</th><td><a href="/e/{r.slug}?y={data.year}">{r.name}</a></td></tr>
						{/each}
					</tbody>
				</table>
			</div>

			{#if data.geomFeatures.length}
				<div class="card">
					<div class="eyebrow">Footprint over time</div>
					<MiniMap features={data.geomFeatures} />
					<p class="hint">Solid: the shape valid in {data.year}. Dashed: other recorded shapes.</p>
				</div>
			{:else if kind?.geometry_hint}
				<div class="notice small">
					No location mapped yet.
					{#if canEdit}<a href="/e/{e.slug}/facts#geometry">Add one →</a>{/if}
				</div>
			{/if}

			{#if data.statusEvents.length}
				<div class="card">
					<div class="eyebrow">Article status history</div>
					<ul class="plain-list small">
						{#each data.statusEvents as s (s.id)}
							<li>
								<span class="date">{s.created_at.slice(0, 10)}</span>
								{s.from_status ?? 'new'} → <strong>{s.to_status}</strong>
								{#if s.note}<div class="muted">{s.note}</div>{/if}
							</li>
						{/each}
					</ul>
				</div>
			{/if}
		</aside>
	</div>
</div>

<style>
	.head {
		margin-bottom: 26px;
	}
	.head h1 {
		font-size: 2.6rem;
		margin: 6px 0 6px;
	}
	.aka {
		margin: 0 0 12px;
	}
	.tags {
		margin-top: 12px;
	}
	.aka .date {
		font-size: 0.75rem;
		color: var(--muted);
	}
	.spacer {
		flex: 1;
	}
	.lede {
		font-size: 1.12rem;
		color: var(--ink-2);
		font-family: var(--serif);
		margin-top: 0;
	}
	.hero {
		margin: 0 0 20px;
	}
	.hero img,
	.hero video {
		max-width: 100%;
		max-height: 70vh;
		border-radius: var(--radius);
		border: 1px solid var(--line);
	}
	.spaces {
		display: grid;
		grid-template-columns: 260px 1fr;
		gap: 16px;
		align-items: start;
	}
	@media (max-width: 700px) {
		.spaces {
			grid-template-columns: 1fr;
		}
	}
	tr.gone {
		opacity: 0.5;
	}
	.groups {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
		gap: 6px 24px;
	}
	.group h3 {
		font-family: var(--sans);
		font-size: 0.82rem;
		text-transform: uppercase;
		letter-spacing: 0.06em;
		color: var(--muted);
		margin: 10px 0 2px;
	}
	.group .date {
		font-size: 0.75rem;
		color: var(--muted);
	}
	.gallery {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
		gap: 10px;
	}
	.tile {
		position: relative;
		display: block;
		aspect-ratio: 4 / 3;
		background: var(--panel);
		border-radius: var(--radius);
		overflow: hidden;
		border: 1px solid var(--line);
	}
	.tile img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		filter: sepia(0.2);
	}
	.tile .file {
		display: grid;
		place-items: center;
		height: 100%;
		color: var(--muted);
	}
	.tile .cap {
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		padding: 3px 6px;
		font-size: 0.72rem;
		background: linear-gradient(transparent, rgba(0, 0, 0, 0.8));
		color: #fff;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.sources {
		font-size: 0.88rem;
		color: var(--ink-2);
		padding-left: 1.4em;
	}
	.sources li:target {
		background: rgba(224, 162, 58, 0.15);
	}
	.infobox table th {
		text-transform: none;
		letter-spacing: 0;
		font-size: 0.8rem;
		width: 40%;
	}
	.yearform {
		display: flex;
		gap: 4px;
	}
	.yearform input {
		width: 80px;
		padding: 4px 6px;
	}
	.yearform button {
		padding: 4px 10px;
	}
	.snapname {
		margin: 10px 0 6px;
		font-size: 1.1rem;
	}
	.snapname .muted {
		font-family: var(--sans);
		font-size: 0.85rem;
		font-weight: 400;
	}
</style>
