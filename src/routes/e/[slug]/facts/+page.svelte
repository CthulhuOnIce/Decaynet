<script lang="ts">
	import { enhance } from '$app/forms';
	import { page } from '$app/state';
	import TemporalFields from '$lib/components/TemporalFields.svelte';
	import { addressLabel } from '$lib/address';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import GeometryPicker from '$lib/components/GeometryPicker.svelte';
	import ConfidenceMark from '$lib/components/ConfidenceMark.svelte';
	import Badge from '$lib/components/Badge.svelte';
	import TagSelect from '$lib/components/TagSelect.svelte';
	import { formatRange, toFuzzyInput } from '$lib/time';
	import { PRECISIONS, CONFIDENCES, type TemporalFact } from '$lib/types';

	let { data, form } = $props();
	const e = $derived(data.entity);
	const kind = $derived(data.vocab.kinds.find((k) => k.id === e.kind));
	const applies = (list: string[] | null) => !list || list.includes(e.kind);

	const attrKeys = $derived(data.vocab.attributeKeys.filter((a) => applies(a.applies_to)));
	// ?rel=occupies&dir=in pre-fills the relation form ("add a tenant to this space")
	let relDirection = $state<'out' | 'in'>(page.url.searchParams.get('dir') === 'in' ? 'in' : 'out');
	const relTypes = $derived(
		data.vocab.relationTypes.filter((r) => applies(relDirection === 'out' ? r.subject_kinds : r.object_kinds))
	);
	let relPredicate = $state(page.url.searchParams.get('rel') ?? '');
	const relOtherKinds = $derived.by(() => {
		const rt = data.vocab.relationTypes.find((r) => r.id === relPredicate);
		return (relDirection === 'out' ? rt?.object_kinds : rt?.subject_kinds) ?? null;
	});
	const geomContext = $derived<GeoJSON.Feature[]>(
		data.geoms.map((g) => ({ type: 'Feature', geometry: g.geojson, properties: {} }))
	);
	const defaultMode = $derived(kind?.geometry_hint === 'line' ? 'line' : kind?.geometry_hint === 'polygon' ? 'polygon' : 'point');
	const isContainer = $derived(['building', 'site'].includes(e.kind));
	const footprints = $derived(data.geoms.filter((g) => g.geojson?.type === 'Polygon' || g.geojson?.type === 'MultiPolygon'));
	const spaceContext = $derived<GeoJSON.Feature[]>([
		...footprints.map((g) => ({ type: 'Feature' as const, geometry: g.geojson, properties: {} })),
		...data.spaces.filter((s) => s.geojson).map((s) => ({ type: 'Feature' as const, geometry: s.geojson!, properties: {} }))
	]);
	const tagById = $derived(Object.fromEntries(data.tags.map((t) => [t.id, t])));
	const tagFacets = $derived(data.vocab.tagFacets.filter((f) => applies(f.applies_to)).map((f) => f.id));
	const msg = (section: string) => (form?.section === section ? form : null);
	const range = (f: Partial<TemporalFact>) =>
		formatRange(f.valid_from, f.valid_from_precision ?? 'year', f.valid_to, f.valid_to_precision ?? 'year') || 'always / undated';
</script>

<svelte:head><title>Facts: {e.name} · {data.settings.site_name}</title></svelte:head>

{#snippet status(section: string)}
	{@const m = msg(section)}
	{#if m?.error}<p class="notice error">{m.error}</p>{:else if m?.ok}<p class="notice ok">{('message' in m && m.message) || 'Saved.'}</p>{/if}
{/snippet}

{#snippet factRow(table: string, f: TemporalFact & Record<string, unknown>, label: string, color?: string)}
	<li class="fact">
		<div class="spread">
			<div>
				{#if color}<Badge {color} label={label} />{:else}<strong>{label}</strong>{/if}
				<span class="date">{range(f)}</span>
				<ConfidenceMark confidence={f.confidence} />
				{#if f.source_id}<span class="muted small">· cited</span>{/if}
				{#if table === 'entity_states' && f.description}<div class="desc small">{f.description}</div>{/if}
				{#if f.note}<div class="muted small note">Note: {f.note}</div>{/if}
			</div>
			<div class="row">
				<form method="post" action="?/deleteFact" use:enhance>
					<input type="hidden" name="section" value={table} />
					<input type="hidden" name="table" value={table} />
					<input type="hidden" name="id" value={f.id} />
					<button class="danger" title="Delete this fact">Delete</button>
				</form>
			</div>
		</div>
		<details>
			<summary class="muted small">{table === 'entity_states' ? 'Edit dates, description & citation' : 'Edit dates & citation'}</summary>
			<form method="post" action="?/updateFact" use:enhance={() => async ({ update }) => update({ reset: false })}>
				<input type="hidden" name="section" value={table} />
				<input type="hidden" name="table" value={table} />
				<input type="hidden" name="id" value={f.id} />
				{#if table === 'entity_states'}
					<div class="field">
						<label for="u-{f.id}-desc">Description <span class="muted">(shown on the timeline)</span></label>
						<textarea id="u-{f.id}-desc" name="description" rows="2" maxlength="1000">{f.description ?? ''}</textarea>
					</div>
				{/if}
				<TemporalFields values={f} sources={data.sources} idPrefix="u-{f.id}" />
				<button>Update</button>
			</form>
		</details>
	</li>
{/snippet}

<div class="page">
	<div class="eyebrow">Structured facts</div>
	<h1><a href="/e/{e.slug}">{e.name}</a></h1>
	<p class="muted intro">
		Everything here is a <strong>temporal fact</strong>: true for a window of time, with a precision, a confidence
		level and an optional citation. Dates accept <code>1926</code>, <code>1920s</code>, <code>c. 1926</code>,
		<code>May 1926</code> or <code>1926-05-12</code>. Leave “Until” blank if it is still true.
	</p>

	<nav class="toc row">
		<a href="#identity">Identity</a><a href="#names">Names</a><a href="#states">Condition</a>
		<a href="#addresses">Addresses</a><a href="#attributes">Attributes</a><a href="#relations">Relations</a><a href="#tags">Tags</a>
		<a href="#geometry">Location & shape</a>{#if isContainer}<a href="#spaces">Spaces</a>{/if}
	</nav>

	<!-- Identity -------------------------------------------------------- -->
	<section id="identity" class="card">
		<h2>Identity & lifespan</h2>
		{@render status('general')}
		<form method="post" action="?/updateEntity" use:enhance={() => async ({ update }) => update({ reset: false })}>
			<input type="hidden" name="section" value="general" />
			<div class="fields">
				<div style="grid-column: span 2">
					<label for="name">Page title (canonical name)</label>
					<input id="name" name="name" value={e.name} required />
				</div>
				<div>
					<label for="slug">Slug</label>
					<input id="slug" value={e.slug} disabled />
				</div>
			</div>
			<div class="field">
				<label for="summary">One-line summary</label>
				<input id="summary" name="summary" value={e.summary ?? ''} />
			</div>
			<div class="fields">
				<div>
					<label for="exists_from">{kind?.start_verb ?? 'Began'}</label>
					<input id="exists_from" name="exists_from" value={toFuzzyInput(e.exists_from, e.exists_from_precision)} placeholder="1926" />
				</div>
				<div>
					<label for="exists_from_precision">precision</label>
					<select id="exists_from_precision" name="exists_from_precision">
						<option value="">auto</option>
						{#each PRECISIONS as p (p)}<option value={p} selected={!!e.exists_from && e.exists_from_precision === p}>{p}</option>{/each}
					</select>
				</div>
				<div>
					<label for="exists_to">{kind?.end_verb ?? 'Ended'}</label>
					<input id="exists_to" name="exists_to" value={toFuzzyInput(e.exists_to, e.exists_to_precision)} placeholder="blank = still exists" />
				</div>
				<div>
					<label for="exists_to_precision">precision</label>
					<select id="exists_to_precision" name="exists_to_precision">
						<option value="">auto</option>
						{#each PRECISIONS as p (p)}<option value={p} selected={!!e.exists_to && e.exists_to_precision === p}>{p}</option>{/each}
					</select>
				</div>
				<div>
					<label for="lifespan_confidence">Confidence</label>
					<select id="lifespan_confidence" name="lifespan_confidence">
						{#each CONFIDENCES as c (c)}<option value={c} selected={e.lifespan_confidence === c}>{c}</option>{/each}
					</select>
				</div>
				{#if e.kind === 'event'}
					<div>
						<label for="event_type">Event type</label>
						<select id="event_type" name="event_type">
							{#each data.vocab.eventTypes as t (t.id)}<option value={t.id} selected={data.event?.event_type === t.id}>{t.label}</option>{/each}
						</select>
					</div>
				{/if}
			</div>
			<p class="hint">The lifespan decides when this appears on the time-machine map. Ending it turns a building into a “ghost”.</p>
			<input type="hidden" name="has_private" value="1" />
			<label class="row" style="gap: 8px; margin: 6px 0 12px; color: var(--ink)">
				<input type="checkbox" name="is_private" checked={e.is_private} />
				Private: hidden from the public until published
			</label>
			<button class="primary">Save identity</button>
		</form>
	</section>

	<!-- Names ----------------------------------------------------------- -->
	<section id="names" class="card">
		<h2>Names over time</h2>
		<p class="hint">Renamings, rebrandings, historic and common names. The map shows whichever name was in use that year.</p>
		{@render status('entity_names')}
		<ul class="plain-list">
			{#each data.names as n (n.id)}
				{@render factRow('entity_names', n, `${n.name} (${n.name_type})`)}
			{:else}
				<li class="muted small">No dated names: the page title is used everywhere.</li>
			{/each}
		</ul>
		<form method="post" action="?/addName" use:enhance>
			<input type="hidden" name="section" value="entity_names" />
			<div class="fields">
				<div style="grid-column: span 2"><label for="n-name">Name</label><input id="n-name" name="name" required /></div>
				<div>
					<label for="n-type">Type</label>
					<select id="n-type" name="name_type">
						{#each ['official', 'common', 'historic', 'alternate', 'nickname', 'misspelling'] as t (t)}<option>{t}</option>{/each}
					</select>
				</div>
			</div>
			<TemporalFields sources={data.sources} idPrefix="n" fromLabel="Used from" toLabel="Used until" />
			<button>Add name</button>
		</form>
	</section>

	<!-- States ---------------------------------------------------------- -->
	<section id="states" class="card">
		<h2>Condition over time</h2>
		<p class="hint">The decay curve: active → vacant → abandoned → ruin → demolished. Colors the map for each year.</p>
		{@render status('entity_states')}
		<ul class="plain-list">
			{#each data.states as s (s.id)}
				{@render factRow('entity_states', s, s.lifecycle_statuses?.label ?? s.status, s.lifecycle_statuses?.color)}
			{:else}
				<li class="muted small">No condition history yet.</li>
			{/each}
		</ul>
		<form method="post" action="?/addState" use:enhance>
			<input type="hidden" name="section" value="entity_states" />
			<div class="fields">
				<div>
					<label for="s-status">Condition</label>
					<select id="s-status" name="status" required>
						{#each data.vocab.statuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}
					</select>
				</div>
			</div>
			<div class="field">
				<label for="s-desc">Description <span class="muted">(optional, shown on the timeline)</span></label>
				<textarea id="s-desc" name="description" rows="2" maxlength="1000" placeholder="Closed after the 1953 fire; the owners moved to Chicago."></textarea>
			</div>
			<TemporalFields sources={data.sources} idPrefix="s" />
			<button>Add condition</button>
		</form>
	</section>

	<!-- Addresses ------------------------------------------------------- -->
	<section id="addresses" class="card">
		<h2>Addresses</h2>
		<p class="hint">Link the street page so the address follows street renamings automatically.</p>
		{@render status('addresses')}
		<ul class="plain-list">
			{#each data.addresses as a (a.id)}
				{@const label = addressLabel(a.house_number, a.street?.name, a.raw_address, data.settings.address_format)}
				{@render factRow('addresses', a, a.street && a.raw_address && a.raw_address !== label ? `${label} (as written: ${a.raw_address})` : label)}
			{:else}
				<li class="muted small">No addresses yet.</li>
			{/each}
		</ul>
		<form method="post" action="?/addAddress" use:enhance>
			<input type="hidden" name="section" value="addresses" />
			<div class="fields">
				<div><label for="a-num">Number</label><input id="a-num" name="house_number" placeholder="123" /></div>
				<div style="grid-column: span 2"><label for="a-street">Street</label><EntityPicker id="a-street" name="street_id" kinds={['street']} placeholder="Main Street" /></div>
				<div><label for="a-unit">Unit</label><input id="a-unit" name="unit" /></div>
				<div><label for="a-zip">ZIP</label><input id="a-zip" name="postal_code" /></div>
			</div>
			<div class="field"><label for="a-raw">As written in the source</label><input id="a-raw" name="raw_address" placeholder="123 Main St." /></div>
			<TemporalFields sources={data.sources} idPrefix="a" />
			<button>Add address</button>
		</form>
	</section>

	<!-- Attributes ------------------------------------------------------ -->
	<section id="attributes" class="card">
		<h2>Attributes</h2>
		{@render status('entity_attributes')}
		<ul class="plain-list">
			{#each data.attributes as a (a.id)}
				{@render factRow('entity_attributes', a, `${a.attribute_keys?.label ?? a.key}: ${typeof a.value === 'string' ? a.value : JSON.stringify(a.value)}${a.attribute_keys?.unit ? ' ' + a.attribute_keys.unit : ''}`)}
			{:else}
				<li class="muted small">No attributes yet.</li>
			{/each}
		</ul>
		<form method="post" action="?/addAttribute" use:enhance>
			<input type="hidden" name="section" value="entity_attributes" />
			<div class="fields">
				<div>
					<label for="at-key">Attribute</label>
					<select id="at-key" name="key" required>
						{#each attrKeys as a (a.id)}<option value={a.id}>{a.label}{a.unit ? ` (${a.unit})` : ''}</option>{/each}
					</select>
				</div>
				<div style="grid-column: span 2"><label for="at-val">Value</label><input id="at-val" name="value" required /></div>
			</div>
			<TemporalFields sources={data.sources} idPrefix="at" />
			<button>Add attribute</button>
		</form>
	</section>

	<!-- Relations ------------------------------------------------------- -->
	<section id="relations" class="card">
		<h2>Relations</h2>
		<p class="hint">Occupants, owners, architects, what an event affected, what a photo depicts, each with its own time window.</p>
		{@render status('relations')}
		<ul class="plain-list">
			{#each data.relations as r (r.id)}
				{@const f = { ...r, created_at: '' } as unknown as TemporalFact & Record<string, unknown>}
				{@render factRow('relations', f, `${r.label} ${r.other_name}${Object.keys(r.qualifiers ?? {}).length ? ' ' + JSON.stringify(r.qualifiers) : ''}`)}
			{:else}
				<li class="muted small">No relations yet.</li>
			{/each}
		</ul>
		<form method="post" action="?/addRelation" use:enhance>
			<input type="hidden" name="section" value="relations" />
			<div class="fields">
				<div>
					<label for="r-dir">Direction</label>
					<select id="r-dir" name="direction" bind:value={relDirection}>
						<option value="out">{e.name} → other</option>
						<option value="in">other → {e.name}</option>
					</select>
				</div>
				<div>
					<label for="r-pred">Relationship</label>
					<select id="r-pred" name="predicate" bind:value={relPredicate} required>
						<option value="" disabled>choose…</option>
						{#each relTypes as r (r.id)}<option value={r.id}>{relDirection === 'out' ? r.label : r.inverse_label}</option>{/each}
					</select>
				</div>
				<div style="grid-column: span 2">
					<label for="r-other">Other page</label>
					<EntityPicker id="r-other" name="other_id" kinds={relOtherKinds} required />
				</div>
				<div style="grid-column: span 2">
					<label for="r-q">Qualifiers</label>
					<input id="r-q" name="qualifiers" placeholder="office=Mayor, floor=2" />
				</div>
			</div>
			<TemporalFields sources={data.sources} idPrefix="r" />
			<button>Add relation</button>
		</form>
	</section>

	<!-- Tags ------------------------------------------------------------ -->
	<section id="tags" class="card">
		<h2>Tags & traits</h2>
		<p class="hint">
			Tags form a tree (Food & drink › Restaurant › Soul food). Tag the most specific trait: the broader ones are implied.
			Tags can be dated too, so a storefront can be a bar 1950–1972 and a church afterwards.
		</p>
		{@render status('entity_tags')}
		<ul class="plain-list">
			{#each data.entityTags as t (t.id)}
				{@const tag = tagById[t.tag_id]}
				{@render factRow('entity_tags', t, tag ? `${tag.facet_label}: ${tag.path}` : 'tag', tag?.color)}
			{:else}
				<li class="muted small">No tags yet.</li>
			{/each}
		</ul>
		<form method="post" action="?/addTag" use:enhance>
			<input type="hidden" name="section" value="entity_tags" />
			<div class="fields">
				<div style="grid-column: span 2">
					<label for="t-tag">Tag</label>
					<TagSelect id="t-tag" tags={data.tags} facets={tagFacets} />
				</div>
			</div>
			<details class="newtag">
				<summary class="small">…or create a new trait</summary>
				<div class="fields">
					<div><label for="t-new">New tag</label><input id="t-new" name="new_label" placeholder="Barbecue" /></div>
					<div>
						<label for="t-parent">Under (sub-trait of)</label>
						<TagSelect id="t-parent" name="new_parent_id" tags={data.tags} placeholder="(top level)" />
					</div>
					<div>
						<label for="t-facet">Facet (if top level)</label>
						<select id="t-facet" name="new_facet">
							<option value="">—</option>
							{#each data.vocab.tagFacets as f (f.id)}<option value={f.id}>{f.label}</option>{/each}
						</select>
					</div>
				</div>
			</details>
			<TemporalFields sources={data.sources} idPrefix="t" fromLabel="Applies from" toLabel="Applies until" />
			<button>Add tag</button>
		</form>
	</section>

	<!-- Geometry -------------------------------------------------------- -->
	<section id="geometry" class="card">
		<h2>Location & shape over time</h2>
		<p class="hint">
			Add a new shape when the thing moved, grew, or was re-platted: end-date the old one rather than deleting it.
			Existing shapes are shown dashed in blue.
		</p>
		{@render status('entity_geometries')}
		<ul class="plain-list">
			{#each data.geoms as g (g.id)}
				{@render factRow('entity_geometries', g, `${g.role}: ${g.geojson?.type ?? 'geometry'}`)}
			{:else}
				<li class="muted small">Not mapped yet.</li>
			{/each}
		</ul>
		<form method="post" action="?/addGeometry" use:enhance>
			<input type="hidden" name="section" value="entity_geometries" />
			<GeometryPicker mode={defaultMode} context={geomContext} />
			<div class="fields" style="margin-top: 8px">
				<div>
					<label for="g-role">Role</label>
					<select id="g-role" name="role">
						{#each ['footprint', 'shape', 'centerline', 'point', 'boundary', 'viewpoint'] as r (r)}<option selected={r === (e.kind === 'building' || e.kind === 'space' ? 'footprint' : 'shape')}>{r}</option>{/each}
					</select>
				</div>
			</div>
			<TemporalFields sources={data.sources} idPrefix="g" fromLabel="Shape valid from" toLabel="Shape valid until" />
			<button>Add shape</button>
		</form>
	</section>

	{#if isContainer}
		<section id="spaces" class="card">
			<h2>Spaces inside this {e.kind}</h2>
			<p class="hint">
				Divide the footprint into storefronts, suites, floors or halls. Each space is its own page with its own dates;
				tenants (businesses, congregations, residents) <em>occupy</em> a space over time, so a single building can show
				a barber in 1950, a church in 1980 and nothing in 2000. Corners snap to the footprint.
			</p>
			{@render status('spaces')}
			{#if data.spaces.length}
				<table>
					<thead><tr><th>Space</th><th>Floor</th><th>Dates</th><th>Tenant today</th><th></th></tr></thead>
					<tbody>
						{#each data.spaces as sp (sp.id)}
							<tr>
								<td><a href="/e/{sp.slug}">{sp.name}</a>{#if sp.unit_label} <span class="muted small">#{sp.unit_label}</span>{/if}</td>
								<td class="mono">{sp.floor ?? '–'}</td>
								<td class="date">{formatRange(sp.exists_from, sp.exists_from_precision, sp.exists_to, sp.exists_to_precision) || 'undated'}</td>
								<td>{sp.tenants ?? (sp.in_use ? `${sp.name} (in use, no tenant page)` : '')}</td>
								<td><a class="btn ghost" href="/e/{sp.slug}/facts?rel=occupies&dir=in#relations">+ Tenant</a></td>
							</tr>
						{/each}
					</tbody>
				</table>
			{/if}
			{#if footprints.length}
				<form method="post" action="?/addSpace" use:enhance>
					<input type="hidden" name="section" value="spaces" />
					<GeometryPicker mode="polygon" context={spaceContext} height={340} each="space" />
					<div class="fields" style="margin-top: 8px">
						<div style="grid-column: span 2">
							<label for="sp-name">Space name</label><input id="sp-name" name="space_name" required placeholder="North storefront" />
							<span class="hint">Pasted several areas? Each becomes its own space, named from the GeoJSON's <code>name</code> (and <code>unit</code>, <code>floor</code>) or numbered after this.</span>
						</div>
						<div><label for="sp-floor">Floor</label><input id="sp-floor" name="floor" type="number" step="1" value="1" /></div>
						<div><label for="sp-unit">Unit / suite</label><input id="sp-unit" name="unit_label" placeholder="101" /></div>
						<div><label for="sp-from">From</label><input id="sp-from" name="valid_from" placeholder="same as building" /></div>
						<div><label for="sp-to">Until</label><input id="sp-to" name="valid_to" placeholder="blank = still there" /></div>
					</div>
					<button>Add space</button>
				</form>
			{:else}
				<p class="notice small">Trace the building's footprint as a polygon in <a href="#geometry">Location & shape</a> first (or in the <a href="/workbench">workbench</a> over a Sanborn sheet).</p>
			{/if}
		</section>
	{/if}

	<section class="card danger-zone" id="danger">
		<h2>Danger zone</h2>
		{@render status('danger')}
		<form
			method="post"
			action="?/deleteEntity"
			use:enhance={({ cancel }) => {
				if (!confirm(`Delete “${e.name}” and every fact attached to it? The change log keeps a record.`)) cancel();
			}}
		>
			<button class="danger">Delete this page</button>
		</form>
	</section>
</div>

<style>
	.intro {
		max-width: 75ch;
	}
	.toc {
		position: sticky;
		top: calc(var(--header-h) + 4px);
		z-index: 10;
		background: var(--bg);
		padding: 8px 0;
		margin-bottom: 8px;
		gap: 14px;
		font-size: 0.88rem;
	}
	section.card {
		margin-bottom: 18px;
		scroll-margin-top: 110px;
	}
	section h2 {
		margin-top: 0;
	}
	.fact .date {
		margin-left: 8px;
	}
	.fact details {
		margin-top: 4px;
	}
	.newtag {
		margin: 8px 0;
	}
	.danger-zone {
		border-color: rgba(224, 85, 43, 0.4);
	}
	ul.plain-list {
		margin-bottom: 12px;
	}
	.desc {
		margin-top: 2px;
		color: var(--ink-2);
		white-space: pre-line;
	}
	.note {
		font-style: italic;
	}
	textarea[name='description'] {
		min-height: 56px;
	}
</style>
