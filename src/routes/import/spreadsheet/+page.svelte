<script lang="ts">
	import { enhance } from '$app/forms';
	import { page } from '$app/state';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import SourcePicker from '$lib/components/SourcePicker.svelte';
	import SourceFields from '$lib/components/SourceFields.svelte';
	import { NEW_SOURCE } from '$lib/sources';
	import { TABLE_FIELDS, TEMPLATE_CSV, guessFields, parseDelimited, type SheetOptions, type SheetRow } from '$lib/tableImport';

	let { data, form } = $props();
	const vocab = $derived(page.data.vocab);
	const settings = $derived(page.data.settings);
	const can = (p: string) => (page.data.perms as string[]).includes(p);

	// ------------------------------------------------------------------ 1. the sheet
	let text = $state('');
	let fileName = $state('');
	let fileInput = $state<HTMLInputElement>();
	let hasHeaders = $state(true);
	const parsed = $derived(parseDelimited(text));
	const width = $derived(Math.max(0, ...parsed.map((r) => r.length)));
	const headers = $derived(hasHeaders && parsed.length ? parsed[0].map((h, i) => h || `Column ${i + 1}`) : Array.from({ length: width }, (_, i) => `Column ${i + 1}`));
	const body = $derived((hasHeaders ? parsed.slice(1) : parsed).map((r) => Array.from({ length: width }, (_, i) => r[i] ?? '')));
	async function readFile(e: Event) {
		const f = (e.currentTarget as HTMLInputElement).files?.[0];
		if (!f) return;
		// read here, in the browser: the file itself is never uploaded or kept
		text = await f.text();
		fileName = f.name;
	}
	function template() {
		const a = document.createElement('a');
		a.href = URL.createObjectURL(new Blob([TEMPLATE_CSV], { type: 'text/csv' }));
		a.download = 'decaynet-spreadsheet-template.csv';
		a.click();
		URL.revokeObjectURL(a.href);
	}

	// ------------------------------------------------------------------ 2. columns
	const attrs = $derived(vocab.attributeKeys as { id: string; label: string; applies_to: string[] | null }[]);
	let mapping = $state<string[]>([]);
	let mappedFor = '';
	// the next sheet with the same columns (the next block from the same directory) keeps the choices
	const remembered = new Map<string, string[]>();
	$effect.pre(() => {
		const key = headers.join('\u0001');
		if (key !== mappedFor) {
			mappedFor = key;
			mapping = remembered.get(key) ?? guessFields(headers, attrs);
		}
	});
	$effect(() => {
		if (mappedFor) remembered.set(mappedFor, [...mapping]);
	});
	const samples = (i: number) =>
		body
			.map((r) => r[i])
			.filter(Boolean)
			.slice(0, 3)
			.join(' · ');
	const hasName = $derived(mapping.includes('name'));

	// ------------------------------------------------------------------ 3. defaults
	let options = $state<SheetOptions>({
		kind: 'organization',
		year: '',
		link_as: 'occupies',
		source_id: '',
		confidence: 'probable',
		points: true,
		geocode: false,
		private: !!page.data.settings.new_pages_private,
		label: ''
	});
	const linkTypes = $derived(
		(vocab.relationTypes as { id: string; label: string; subject_kinds: string[] | null; object_kinds: string[] | null }[]).filter(
			(t) =>
				(!t.subject_kinds || t.subject_kinds.includes(options.kind)) &&
				(!t.object_kinds || t.object_kinds.some((k) => ['building', 'site', 'parcel', 'space'].includes(k))) &&
				t.id !== 'part_of'
		)
	);
	$effect(() => {
		if (linkTypes.length && !linkTypes.some((t) => t.id === options.link_as)) options.link_as = linkTypes[0].id;
	});
	const sheetJson = $derived(JSON.stringify({ headers, rows: body, mapping, options }));
	// what the preview depends on (the source, label and confidence can change after it)
	const matchKey = $derived(JSON.stringify({ headers, rows: body, mapping, kind: options.kind, year: options.year, link: options.link_as, points: options.points, geocode: options.geocode }));
	const sourceTitle = $derived(
		options.source_id === NEW_SOURCE ? 'a new source' : (data.sources.find((x: { id: string }) => x.id === options.source_id)?.title ?? '')
	);

	// ------------------------------------------------------------------ 4. review
	let rows = $state<SheetRow[]>([]);
	let previewedJson = $state('');
	let pendingJson = '';
	let geocoded = $state(0);
	let busy = $state(false);
	let picking = $state<number | null>(null);
	$effect(() => {
		const p = form && 'preview' in form ? form.preview : null;
		if (p) {
			rows = structuredClone(p.rows) as SheetRow[];
			geocoded = p.geocoded;
			previewedJson = pendingJson;
		}
	});
	$effect(() => {
		const a = form && 'applied' in form ? form.applied : null;
		if (!a) return;
		// done with this sheet: nothing of it stays on the page; the source stays picked for the next one
		rows = [];
		text = '';
		fileName = '';
		if (fileInput) fileInput.value = '';
		options.source_id = a.source_id;
	});
	const stale = $derived(rows.length > 0 && previewedJson !== matchKey);
	const kindLabel = (k: string) => vocab.kinds.find((x: { id: string }) => x.id === k)?.label ?? k;
	const spatial = (k: string) => !['organization', 'person', 'event', 'media'].includes(k);
	const taken = $derived(rows.filter((r) => r.include));
	const counts = $derived({
		rows: taken.length,
		created: taken.filter((r) => !r.use_existing && !r.shares).length,
		existing: taken.filter((r) => r.use_existing).length,
		placed: taken.filter((r) => r.place_id).length,
		points: taken.filter((r) => !r.place_id && r.point).length,
		unplaced: taken.filter((r) => !spatial(r.kind) && !r.place_id && !r.point).length,
		issues: taken.filter((r) => r.issues.length).length
	});
	const choices = $derived(
		JSON.stringify(
			Object.fromEntries(
				rows.map((r) => [
					r.n,
					{ include: r.include, use_existing: r.use_existing, place_id: r.place_id, point: r.point, lat: r.lat, lon: r.lon, tag_ids: r.tags.map((t) => t.id) }
				])
			)
		)
	);
	const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
	function pickPlace(r: SheetRow, p: { id: string; name: string; slug?: string; kind?: string } | null) {
		r.place_id = p?.id ?? null;
		r.place = p ? { id: p.id, slug: p.slug ?? '', name: p.name, kind: p.kind ?? 'building' } : null;
		r.space = null;
		r.place_how = p ? 'named' : null;
		if (p) {
			r.point = false;
			picking = null;
		}
	}
</script>

<svelte:head><title>Spreadsheet import</title></svelte:head>

<div class="page sheet">
	<div class="eyebrow"><a href="/import">Import</a> · Spreadsheet</div>
	<h1>Spreadsheet import</h1>
	<p class="muted intro">
		A spreadsheet of every business on a block from a city directory, say, becomes pages in one go, each linked to the building (or
		storefront) it was in that year, so they show on the map. Rows are matched to pages that already exist; nothing is written until
		you've looked over the preview, and the whole import can be undone.
		<a href="{page.data.settings.source_code_url}/blob/main/CSVs.md" target="_blank" rel="noopener">How to write a sheet ↗</a>
	</p>

	{#if form && 'error' in form && form.error}<p class="notice error">{form.error}</p>{/if}
	{#if form && 'undone' in form && form.undone != null}<p class="notice ok">Undone: removed {plural(form.undone, 'page')} and the links it made.</p>{/if}
	{#if form && 'applied' in form && form.applied}
		<p class="notice ok">
			Imported: {plural(form.applied.created, 'new page')}, {plural(form.applied.linked, 'link')} to buildings{form.applied.points
				? `, ${plural(form.applied.points, 'new map point')}`
				: ''}{form.applied.addresses ? `, ${plural(form.applied.addresses, 'address', 'addresses')} kept on unplaced pages` : ''}.
			{#if can('moderate')}Undo it under Recent imports below if something's wrong.{/if}
		</p>
	{/if}

	<section class="card step">
		<h2><span class="num">1</span> The sheet</h2>
		<div class="row">
			<label class="btn ghost filebtn">
				Choose a CSV or TSV file
				<input type="file" accept=".csv,.tsv,.txt,text/csv,text/tab-separated-values" onchange={readFile} bind:this={fileInput} />
			</label>
			<span class="muted small">{fileName || 'or paste the cells below (straight from a spreadsheet works)'}</span>
			<span class="spacer"></span>
			<button type="button" class="link" onclick={template}>Download a template</button>
		</div>
		<textarea bind:value={text} rows="6" placeholder={TEMPLATE_CSV} spellcheck="false" aria-label="Spreadsheet rows"></textarea>
		<div class="row small">
			<label class="check"><input type="checkbox" bind:checked={hasHeaders} /> The first row holds the column names</label>
			{#if parsed.length}<span class="muted">{plural(body.length, 'row')}, {plural(width, 'column')}</span>{/if}
		</div>
		<p class="hint">The sheet is only read: it isn't uploaded as a file or kept anywhere, and it's cleared once imported. What gets cited is the source you pick below.</p>
	</section>

	{#if body.length}
		<section class="card step">
			<h2><span class="num">2</span> What each column is</h2>
			<p class="hint">Guessed from the headers; change any. Columns set to Ignore aren't read.</p>
			<table class="cols">
				<thead><tr><th>Column</th><th>First values</th><th>Is</th></tr></thead>
				<tbody>
					{#each headers as h, i (i)}
						<tr class:ignored={!mapping[i]}>
							<td><strong>{h}</strong></td>
							<td class="muted small sample">{samples(i) || '(empty)'}</td>
							<td>
								<select bind:value={mapping[i]} aria-label="What “{h}” is">
									<option value="">Ignore</option>
									{#each TABLE_FIELDS as f (f.id)}
										<option value={f.id} disabled={mapping.includes(f.id) && mapping[i] !== f.id}>{f.label}{f.hint ? ` (${f.hint})` : ''}</option>
									{/each}
									<optgroup label="A fact on the page">
										{#each attrs as a (a.id)}<option value="attr:{a.id}" disabled={mapping.includes(`attr:${a.id}`) && mapping[i] !== `attr:${a.id}`}>{a.label}</option>{/each}
									</optgroup>
								</select>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
			{#if !hasName}<p class="notice error small">Pick the column that holds the names.</p>{/if}
		</section>

		<section class="card step">
			<h2><span class="num">3</span> For every row</h2>
			<div class="source-box" class:missing={!options.source_id}>
				<label for="so-src">Made from <span class="req">required</span></label>
				<SourcePicker id="so-src" sources={data.sources} allowNone={false} newLabel="New source…" placeholder="The directory, census or map you typed it from…" bind:value={options.source_id} />
				<span class="hint">Cited on every link, name, tag and fact the import adds, with each row's <em>Source detail</em> (page, entry). The sheet is a copy of this, not the source.</span>
				{#if options.source_id === NEW_SOURCE}
					<SourceFields prefix="ns_" idPrefix="sh-ns" form="sheet-apply" kind="directory" note="Saved to the source library when you import, so the next sheet from it can pick it." />
				{/if}
			</div>
			<div class="fields">
				<div>
					<label for="so-kind">Pages are</label>
					<select id="so-kind" bind:value={options.kind}>
						{#each vocab.kinds as k (k.id)}<option value={k.id}>{k.label}</option>{/each}
					</select>
					<span class="hint">unless a Kind column says otherwise</span>
				</div>
				<div>
					<label for="so-year">Listed in</label>
					<input id="so-year" bind:value={options.year} placeholder="1925" />
					<span class="hint">the directory's year, for rows with no dates of their own</span>
				</div>
				{#if !spatial(options.kind)}
					<div>
						<label for="so-link">Linked to the building as</label>
						<select id="so-link" bind:value={options.link_as}>
							{#each linkTypes as t (t.id)}<option value={t.id}>{t.label}</option>{/each}
						</select>
					</div>
				{/if}
				<div>
					<label for="so-conf">Confidence</label>
					<select id="so-conf" bind:value={options.confidence}>
						{#each ['certain', 'probable', 'approximate', 'speculative'] as c (c)}<option>{c}</option>{/each}
					</select>
				</div>
				<div class="wide">
					<label for="so-label">Label</label>
					<input id="so-label" bind:value={options.label} placeholder="1925 city directory, Broadway 500–700" />
				</div>
			</div>
			<div class="checks">
				<label class="check"><input type="checkbox" bind:checked={options.points} /> Addresses that match no building become new map points (from Latitude / Longitude columns)</label>
				<label class="check" class:off={!options.points}>
					<input type="checkbox" bind:checked={options.geocode} disabled={!options.points} /> …or look them up on OpenStreetMap: today's numbering, the
					first 25 addresses, about one a second
				</label>
				<label class="check"><input type="checkbox" bind:checked={options.private} /> New pages start private</label>
			</div>
			<form
				method="post"
				action="?/preview"
				use:enhance={() => {
					busy = true;
					pendingJson = matchKey;
					return async ({ update }) => {
						await update({ reset: false });
						busy = false;
					};
				}}
			>
				<input type="hidden" name="sheet" value={sheetJson} />
				<button class="primary" disabled={!hasName || busy}>
					{busy ? (options.geocode ? 'Matching and looking up addresses…' : 'Matching…') : `Preview ${plural(body.length, 'row')}`}
				</button>
			</form>
		</section>
	{/if}

	{#if rows.length}
		<section class="card step review">
			<h2><span class="num">4</span> Check and import</h2>
			<p class="summary">
				{plural(counts.rows, 'row')}: {plural(counts.created, 'new page')}, {counts.existing} added to existing pages ·
				{counts.placed} placed in buildings{counts.points ? `, ${plural(counts.points, 'new map point')}` : ''}{counts.unplaced
					? `, ${counts.unplaced} not placed yet (their address is kept)`
					: ''}{geocoded ? ` · ${geocoded} looked up` : ''}
			</p>
			{#if stale}<p class="notice small">The sheet or the settings changed since this preview: preview again before importing.</p>{/if}
			<div class="table-wrap">
				<table class="rows">
					<thead>
						<tr>
							<th><input type="checkbox" aria-label="All rows" checked={rows.every((r) => r.include)} onchange={(e) => rows.forEach((r) => (r.include = e.currentTarget.checked))} /></th>
							<th>Row</th>
							<th>Name</th>
							<th>Page</th>
							<th>In</th>
							<th>When</th>
						</tr>
					</thead>
					<tbody>
						{#each rows as r (r.n)}
							<tr class:off={!r.include} class:warn={r.issues.length > 0}>
								<td class="pick"><input type="checkbox" bind:checked={r.include} aria-label="Import row {r.n}" /></td>
								<td class="mono muted rowno">{r.n}</td>
								<td>
									<strong>{r.name}</strong>
									{#if r.kind !== options.kind}<span class="muted small">{kindLabel(r.kind)}</span>{/if}
									{#if r.address}<div class="muted small">{r.address}{r.unit ? `, #${r.unit}` : ''}</div>{/if}
									{#if r.tags.length || r.missing_tags.length}
										<div class="small">
											{#each r.tags as t (t.id)}<span class="tag">{t.label}</span>{/each}
											{#each r.missing_tags as t (t)}<span class="tag missing" title="No such tag: skipped (add it under Tags first)">{t}?</span>{/each}
										</div>
									{/if}
									{#each r.issues as i (i)}<div class="issue small">{i}</div>{/each}
								</td>
								<td class="pagecell" data-label="Page">
									{#if r.same || r.similar}
										{@const m = (r.same ?? r.similar)!}
										<select bind:value={r.use_existing} aria-label="Page for row {r.n}">
											<option value={null}>New page</option>
											<option value={m.id}>{r.same ? 'Existing' : 'Same as'}: {m.name}</option>
										</select>
										{#if r.use_existing}<a class="small" href="/e/{m.slug}" target="_blank" rel="noopener">open ↗</a>{/if}
									{:else if r.shares}
										<span class="muted">same page as row {r.shares}</span>
									{:else}
										<span class="muted">New {kindLabel(r.kind).toLowerCase()}</span>
									{/if}
								</td>
								<td class="placecell" data-label="In">
									{#if spatial(r.kind) && r.kind !== 'space'}
										<span class="muted small">{r.lat != null ? 'its own point' : r.address ? 'address only' : '–'}</span>
									{:else if r.place_id && r.place}
										<a href="/e/{r.place.slug}" target="_blank" rel="noopener">{r.place.name}</a>
										<span class="how small">{r.place_how === 'named' ? 'named' : r.space ? 'by address & unit' : 'by address'}</span>
										<button type="button" class="ghost x" title="Don't link it" onclick={() => pickPlace(r, null)}>✕</button>
									{:else if picking === r.n}
										<EntityPicker name="pick-{r.n}" kinds={['building', 'site', 'parcel', 'space']} placeholder="Find the building…" onpick={(p) => pickPlace(r, p)} />
									{:else}
										{#if r.lat != null && options.points}
											<label class="check small"><input type="checkbox" bind:checked={r.point} /> new point{r.place_how === 'geocoded' ? ' (looked up)' : ''}</label>
										{:else}
											<span class="muted small">not placed</span>
										{/if}
										<button type="button" class="link small" onclick={() => (picking = r.n)}>choose…</button>
									{/if}
								</td>
								<td class="small whencell" data-label="When">{r.when}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
			<form
				id="sheet-apply"
				method="post"
				action="?/apply"
				class="row"
				use:enhance={({ cancel }) => {
					if (!confirm(`Import ${plural(counts.rows, 'row')}?`)) return cancel();
					busy = true;
					return async ({ update }) => {
						await update({ reset: false });
						busy = false;
					};
				}}
			>
				<input type="hidden" name="sheet" value={sheetJson} />
				<input type="hidden" name="choices" value={choices} />
				<button class="primary" disabled={!counts.rows || stale || busy || !options.source_id}>{busy ? 'Importing…' : `Import ${plural(counts.rows, 'row')}`}</button>
				{#if !options.source_id}
					<span class="issue small">Pick what the sheet was made from (step 3) first.</span>
				{:else}
					<span class="muted small">cited to {sourceTitle}</span>
				{/if}
				{#if counts.issues}<span class="muted small">· {plural(counts.issues, 'row')} with something to check (in amber)</span>{/if}
			</form>
		</section>
	{/if}

	{#if data.batches.length}
		<section class="card">
			<h2>Recent spreadsheet imports</h2>
			<ul class="plain-list small batches">
				{#each data.batches as b (b.id)}
					{@const s = (b.summary ?? {}) as { label?: string; rows?: number; created?: number; linked?: number; points?: number }}
					<li class:undone={b.undone_at}>
						<span>
							<strong>{s.label || 'Spreadsheet'}</strong> · {plural(s.rows ?? 0, 'row')}: {s.created ?? 0} new, {s.linked ?? 0} links{s.points ? `, ${s.points} points` : ''}
							<span class="muted">· {b.by?.display_name ?? 'someone'} · {new Date(b.created_at).toLocaleString()}{b.undone_at ? ' · undone' : ''}</span>
						</span>
						{#if can('moderate') && !b.undone_at}
							<form
								method="post"
								action="?/undo"
								use:enhance={({ cancel }) => {
									if (!confirm(`Undo this import? It deletes the ${s.created ?? 0} page(s) it made and the links, names, tags and facts it added to existing pages.`)) cancel();
								}}
							>
								<input type="hidden" name="batch" value={b.id} />
								<button class="danger small-btn">Undo</button>
							</form>
						{/if}
					</li>
				{/each}
			</ul>
		</section>
	{/if}
	<p class="muted small">Settings: addresses are read as “{settings.address_format === 'street_number' ? 'Broadway 512' : '512 Broadway'}”, and either way works.</p>
</div>

<style>
	.intro {
		max-width: 75ch;
	}
	.step {
		margin-top: 14px;
	}
	.source-box {
		display: grid;
		gap: 4px;
		margin-bottom: 12px;
		padding: 10px 12px;
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
	}
	.source-box.missing {
		border-color: var(--amber);
	}
	.source-box label {
		margin: 0;
	}
	.req {
		margin-left: 4px;
		font-size: 0.72rem;
		font-weight: normal;
		color: var(--amber);
	}
	.step h2 {
		display: flex;
		gap: 8px;
		align-items: center;
		margin: 0 0 10px;
		font-size: 1.15rem;
	}
	.num {
		display: inline-grid;
		place-items: center;
		width: 1.6em;
		height: 1.6em;
		border-radius: 50%;
		background: var(--panel-2);
		font: 600 0.85rem var(--sans);
	}
	textarea {
		width: 100%;
		margin-top: 8px;
		font-family: var(--mono);
		font-size: 0.82rem;
	}
	.row {
		display: flex;
		gap: 10px;
		align-items: center;
		flex-wrap: wrap;
	}
	.spacer {
		flex: 1;
	}
	.filebtn {
		position: relative;
		overflow: hidden;
	}
	.filebtn input {
		position: absolute;
		inset: 0;
		opacity: 0;
		cursor: pointer;
	}
	.check {
		display: flex;
		gap: 6px;
		align-items: baseline;
		margin: 0;
		font-weight: normal;
		color: var(--ink-2);
	}
	.check.off {
		opacity: 0.5;
	}
	.checks {
		display: grid;
		gap: 6px;
		margin: 12px 0;
	}
	table {
		width: 100%;
		border-collapse: collapse;
	}
	th,
	td {
		padding: 5px 6px;
		text-align: left;
		vertical-align: top;
		border-bottom: 1px solid var(--line);
	}
	th {
		font-size: 0.78rem;
		color: var(--muted);
		font-weight: 500;
	}
	.cols select {
		width: 100%;
	}
	.cols tr.ignored td:first-child {
		color: var(--muted);
	}
	.sample {
		max-width: 28ch;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.fields {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
		gap: 10px 14px;
	}
	.fields .wide {
		grid-column: span 2;
	}
	.fields .hint {
		display: block;
		margin-top: 2px;
	}
	.summary {
		margin: 0 0 8px;
	}
	.table-wrap {
		overflow-x: auto;
		margin-bottom: 10px;
	}
	.rows tr.off td {
		opacity: 0.45;
	}
	.rows tr.warn td:nth-child(3) {
		box-shadow: inset 3px 0 0 var(--amber);
	}
	.issue {
		color: var(--amber);
	}
	.tag {
		display: inline-block;
		margin: 2px 4px 0 0;
		padding: 0 6px;
		border: 1px solid var(--line-2);
		border-radius: 999px;
	}
	.tag.missing {
		border-style: dashed;
		color: var(--muted);
	}
	.how {
		margin-left: 4px;
		color: var(--muted);
	}
	.pagecell select {
		max-width: 22ch;
	}
	.placecell {
		min-width: 14rem;
	}
	button.link {
		background: none;
		border: 0;
		padding: 0;
		color: var(--rust-2);
		font: inherit;
		cursor: pointer;
	}
	button.x {
		padding: 0 6px;
	}
	.batches li {
		display: flex;
		gap: 10px;
		justify-content: space-between;
		align-items: center;
		padding: 4px 0;
	}
	.batches li.undone {
		opacity: 0.55;
	}
	.batches form {
		margin: 0;
	}
	@media (max-width: 700px) {
		.fields .wide {
			grid-column: auto;
		}
		/* each row a card: the name on top, then labelled lines */
		.rows thead tr th:not(:first-child) {
			display: none;
		}
		.rows,
		.rows tbody {
			display: block;
		}
		.rows tbody tr {
			display: grid;
			grid-template-columns: 2rem 1fr;
			column-gap: 4px;
			padding: 8px 0;
			border-bottom: 1px solid var(--line);
		}
		.rows td {
			border: 0;
			padding: 2px 0;
		}
		.rows td.rowno {
			display: none;
		}
		.rows td.pagecell,
		.rows td.placecell,
		.rows td.whencell {
			grid-column: 2;
			min-width: 0;
			display: flex;
			gap: 6px;
			align-items: baseline;
			flex-wrap: wrap;
		}
		.rows td[data-label]::before {
			content: attr(data-label);
			width: 3.2rem;
			flex: none;
			color: var(--muted);
			font-size: 0.75rem;
		}
		.rows tr.warn td:nth-child(3) {
			box-shadow: none;
		}
		.rows tr.warn {
			box-shadow: inset 3px 0 0 var(--amber);
		}
		.pagecell select {
			max-width: 100%;
		}
	}
</style>
