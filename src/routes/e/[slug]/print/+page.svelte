<script lang="ts">
	import { onMount } from 'svelte';
	import Badge from '$lib/components/Badge.svelte';
	import ShapeSketch from '$lib/components/ShapeSketch.svelte';
	import Timeline from '$lib/components/Timeline.svelte';
	import { isImage, mediaSrc } from '$lib/media';
	import { formatFuzzy, formatRange } from '$lib/time';
	import type { RelationRow } from '$lib/types';

	let { data } = $props();
	const e = $derived(data.entity);
	const snap = $derived(data.snapshot);
	const kind = $derived(data.vocab.kinds.find((k) => k.id === e.kind));
	const lifespan = $derived(formatRange(e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision));
	const sourceIndex = $derived(Object.fromEntries(data.sources.map((s, i) => [s.id, i + 1])));
	const akas = $derived(snap.other_names.filter((n) => n.name.toLowerCase() !== e.name.toLowerCase()));
	const shapes = $derived(data.geomFeatures.filter((f) => f.properties?.role !== 'viewpoint'));
	const images = $derived(
		data.gallery
			.map((g) => {
				const mi = Array.isArray(g.media_items) ? g.media_items[0] : g.media_items;
				const src = mi && isImage(mi.media_type) ? mediaSrc(mi.storage_path, mi.external_url) : null;
				return src ? { id: g.id, src, caption: [formatFuzzy(g.exists_from, g.exists_from_precision), g.name].filter(Boolean).join(' · ') } : null;
			})
			.filter((x) => x !== null)
			.slice(0, 6)
	);
	const mainImage = $derived(data.media && isImage(data.media.media_type) ? mediaSrc(data.media.storage_path, data.media.external_url) : null);
	// links grouped by how they read ("occupied by", "is on"…); media shows as pictures
	const groups = $derived.by(() => {
		const m = new Map<string, RelationRow[]>();
		for (const r of data.relations) {
			if (r.other_kind === 'media') continue;
			if (!m.has(r.label)) m.set(r.label, []);
			m.get(r.label)!.push(r);
		}
		return [...m.entries()];
	});

	// what goes on paper (remembered for this visit only)
	const SECTIONS = [
		['facts', 'Key facts'],
		['article', 'Article'],
		['shapes', 'Shapes'],
		['timeline', 'Timeline'],
		['links', 'Connections'],
		['pictures', 'Pictures'],
		['sources', 'Sources']
	] as const;
	type Section = (typeof SECTIONS)[number][0];
	let show = $state<Record<Section, boolean>>({ facts: true, article: true, shapes: true, timeline: true, links: true, pictures: true, sources: true });
	const has: Record<Section, boolean> = $derived({
		facts: true,
		article: !!data.html,
		shapes: shapes.length > 0,
		timeline: data.timeline.length > 0,
		links: groups.length > 0,
		pictures: images.length > 0 || !!mainImage,
		sources: data.sources.length > 0
	});
	const on = (s: Section) => show[s] && has[s];
	const printed = $derived(new Date(data.printedAt).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' }));
	const yearNote = $derived(data.year !== new Date().getFullYear() ? ` as of ${data.year}` : '');
	const metaLine = $derived([kind?.label ?? e.kind, lifespan, snap.address].filter(Boolean).join(' · '));
	const range = (r: { valid_from: string | null; valid_from_precision: never; valid_to: string | null; valid_to_precision: never }) =>
		r.valid_from || r.valid_to ? ` (${formatRange(r.valid_from, r.valid_from_precision, r.valid_to, r.valid_to_precision)})` : '';

	// paper can't unfold anything: open every fold-out (e.g. the timeline's undated facts)
	let sheet: HTMLElement | undefined = $state();
	const unfold = () => sheet?.querySelectorAll('details').forEach((d) => (d.open = true));
	onMount(() => {
		unfold();
		window.addEventListener('beforeprint', unfold);
		return () => window.removeEventListener('beforeprint', unfold);
	});
</script>

<svelte:head>
	<title>{e.name} (printable) · {data.settings.site_name}</title>
	<meta name="robots" content="noindex" />
</svelte:head>

<div class="print-sheet">
	<div class="toolbar no-print">
		<a href="/e/{e.slug}{data.year !== new Date().getFullYear() ? `?y=${data.year}` : ''}">← Back to the page</a>
		<span class="spacer"></span>
		<fieldset>
			<legend>Include</legend>
			{#each SECTIONS as [id, label] (id)}
				{#if has[id]}<label><input type="checkbox" bind:checked={show[id]} /> {label}</label>{/if}
			{/each}
		</fieldset>
		<button class="primary" onclick={() => window.print()}>Print or save as PDF</button>
	</div>

	<article class="sheet" bind:this={sheet}>
		<header>
			<div class="site">{data.settings.site_name} · {data.settings.region_name}</div>
			<h1>{e.name}</h1>
			<p class="meta">
				{metaLine}
				{#if snap.status}<Badge color={snap.status.color} label={snap.status.label} />{/if}
			</p>
			{#if e.summary}<p class="summary">{e.summary}</p>{/if}
		</header>

		{#if on('facts')}
			<section class="facts">
				<table>
					<tbody>
						{#if lifespan}<tr><th>{kind?.start_verb ?? 'From'} – {kind?.end_verb ?? 'until'}</th><td>{lifespan}</td></tr>{/if}
						{#if snap.status}<tr><th>Condition{yearNote}</th><td>{snap.status.label}</td></tr>{/if}
						{#if snap.address}<tr><th>Address{yearNote}</th><td>{snap.address}</td></tr>{/if}
						{#if akas.length}
							<tr>
								<th>Also known as</th>
								<td>
									{#each akas as n, i (i)}{i ? '; ' : ''}{n.name}<span class="muted">{range(n as never)}</span>{/each}
								</td>
							</tr>
						{/if}
						{#each snap.attributes as a (a.key)}
							<tr>
								<th>{a.label}</th>
								<td>{typeof a.value === 'number' ? a.value.toLocaleString() : String(a.value)}{a.unit ? ` ${a.unit}` : ''}</td>
							</tr>
						{/each}
						{#if data.tags.length}<tr><th>Tags</th><td>{data.tags.map((t) => t.label).join(', ')}</td></tr>{/if}
					</tbody>
				</table>
			</section>
		{/if}

		{#if on('pictures') && mainImage}
			<figure class="main-image"><img src={mainImage} alt={e.name} /></figure>
		{/if}

		{#if on('article')}
			<section class="prose article">{@html data.html}</section>
		{/if}

		{#if on('shapes')}
			<section class="avoid-break">
				<h2>Shapes</h2>
				<ShapeSketch features={shapes} label="Shapes of {e.name}" />
				<p class="caption">Solid: in use in {data.year}. Dashed: earlier or later shapes.</p>
			</section>
		{/if}

		{#if on('timeline')}
			<section>
				<h2>Timeline</h2>
				<Timeline rows={data.timeline} highlightYear={data.year} {sourceIndex} />
			</section>
		{/if}

		{#if on('links')}
			<section>
				<h2>Connections</h2>
				<dl class="links">
					{#each groups as [label, rows] (label)}
						<dt>{label}</dt>
						<dd>
							{#each rows as r, i (r.id)}{i ? '; ' : ''}{r.other_name}<span class="muted">{range(r as never)}</span>{#if r.source_id && sourceIndex[r.source_id]}<sup
										>[{sourceIndex[r.source_id]}]</sup
									>{/if}{/each}
						</dd>
					{/each}
				</dl>
			</section>
		{/if}

		{#if on('pictures') && images.length}
			<section>
				<h2>Pictures</h2>
				<div class="pictures">
					{#each images as im (im.id)}
						<figure class="avoid-break"><img src={im.src} alt={im.caption} /><figcaption>{im.caption}</figcaption></figure>
					{/each}
				</div>
			</section>
		{/if}

		{#if on('sources')}
			<section>
				<h2>Sources</h2>
				<ol class="sources">
					{#each data.sources as s (s.id)}
						<li>
							<strong>{s.title}</strong>{#if s.author}, {s.author}{/if}{#if s.publisher}. {s.publisher}{/if}{#if s.published_on}, {formatFuzzy(s.published_on, s.published_precision)}{/if}{#if s.repository}. {s.repository}{/if}{#if s.call_number}, {s.call_number}{/if}.
							{#if s.url}<div class="url">{s.url}</div>{/if}
							{#if s.archive_url}<div class="url">Archived: {s.archive_url}</div>{/if}
						</li>
					{/each}
				</ol>
			</section>
		{/if}

		<footer>
			From {data.settings.site_name}, {data.pageUrl}{yearNote ? ` (${data.year})` : ''}. Printed {printed}.
		</footer>
	</article>
</div>

<style>
	/* paper colours for everything on this page, including the shared timeline and article styles */
	:global(html:has(.print-sheet)) {
		--bg: #ffffff;
		--bg-2: #f6f3ee;
		--panel: #f6f3ee;
		--panel-2: #efe9e1;
		--line: #d9d1c6;
		--line-2: #c4b9ab;
		--ink: #1d1813;
		--ink-2: #3d352d;
		--muted: #6f6457;
		--rust: #a8431c;
		--rust-2: #a8431c;
		--amber: #8a5a00;
		color-scheme: light;
	}
	.toolbar {
		position: sticky;
		top: 0;
		z-index: 5;
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 10px 16px;
		padding: 10px 16px;
		background: var(--panel);
		border-bottom: 1px solid var(--line);
	}
	.toolbar fieldset {
		display: flex;
		flex-wrap: wrap;
		gap: 4px 12px;
		margin: 0;
		padding: 0;
		border: 0;
	}
	.toolbar legend {
		float: left;
		margin-right: 4px;
		color: var(--muted);
		font-size: 0.85rem;
	}
	.toolbar label {
		display: inline-flex;
		gap: 4px;
		align-items: center;
		margin: 0;
		font-size: 0.85rem;
		color: var(--ink);
		font-weight: normal;
	}
	.spacer {
		flex: 1;
	}
	.sheet {
		max-width: 46rem;
		margin: 0 auto;
		padding: 32px 24px 48px;
		color: var(--ink);
		font-size: 11pt;
		line-height: 1.5;
	}
	.site {
		font-size: 0.8rem;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--muted);
	}
	h1 {
		margin: 4px 0 6px;
		font-family: var(--serif);
		font-size: 2rem;
		line-height: 1.15;
	}
	.meta {
		display: flex;
		flex-wrap: wrap;
		gap: 4px 10px;
		align-items: center;
		margin: 0;
		color: var(--ink-2);
	}
	.summary {
		margin: 10px 0 0;
		font-size: 1.05rem;
	}
	header {
		padding-bottom: 14px;
		border-bottom: 2px solid var(--ink);
	}
	section {
		margin-top: 22px;
	}
	h2 {
		margin: 0 0 8px;
		font-family: var(--serif);
		font-size: 1.2rem;
		border-bottom: 1px solid var(--line);
		padding-bottom: 3px;
	}
	.facts table {
		width: 100%;
		border-collapse: collapse;
	}
	.facts th,
	.facts td {
		text-align: left;
		vertical-align: top;
		padding: 4px 8px 4px 0;
		border-bottom: 1px solid var(--line);
	}
	.facts th {
		width: 30%;
		font-weight: 600;
		color: var(--ink-2);
	}
	.muted {
		color: var(--muted);
	}
	.caption {
		margin: 4px 0 0;
		font-size: 0.8rem;
		color: var(--muted);
	}
	.links {
		display: grid;
		grid-template-columns: max-content 1fr;
		gap: 4px 16px;
		margin: 0;
	}
	.links dt {
		font-weight: 600;
		color: var(--ink-2);
	}
	.links dd {
		margin: 0;
	}
	.main-image {
		margin: 18px 0 0;
	}
	.main-image img {
		max-width: 100%;
		max-height: 60vh;
		display: block;
		margin: 0 auto;
	}
	.pictures {
		display: grid;
		grid-template-columns: repeat(3, 1fr);
		gap: 10px;
	}
	.pictures figure {
		margin: 0;
	}
	.pictures img {
		width: 100%;
		aspect-ratio: 4 / 3;
		object-fit: cover;
		display: block;
	}
	figcaption {
		font-size: 0.75rem;
		color: var(--muted);
		margin-top: 2px;
	}
	.sources {
		padding-left: 1.4em;
		margin: 0;
	}
	.sources li + li {
		margin-top: 6px;
	}
	.url {
		font-family: var(--mono);
		font-size: 0.75rem;
		color: var(--ink-2);
		overflow-wrap: anywhere;
	}
	footer {
		margin-top: 32px;
		padding-top: 8px;
		border-top: 1px solid var(--line);
		font-size: 0.8rem;
		color: var(--muted);
		overflow-wrap: anywhere;
	}
	/* on paper, links can't be clicked: show them as text */
	.sheet :global(a) {
		color: inherit;
		text-decoration: none;
	}
	.sheet :global(.prose a) {
		text-decoration: underline dotted;
	}
	@media (max-width: 600px) {
		.pictures {
			grid-template-columns: repeat(2, 1fr);
		}
		.sheet {
			padding: 20px 16px 40px;
		}
	}
	@media print {
		.no-print {
			display: none !important;
		}
		.sheet {
			max-width: none;
			padding: 0;
		}
		.avoid-break,
		.pictures figure,
		.sources li {
			break-inside: avoid;
		}
		h2 {
			break-after: avoid;
		}
	}
	@page {
		margin: 18mm 16mm;
	}
</style>
