<script lang="ts">
	import KindBadge from '$lib/components/KindBadge.svelte';
	import { looksLikeAddress } from '$lib/address';
	import { slugifyClient } from '$lib/slug';
	import { yearOf } from '$lib/time';
	import type { AddressHit, GeoAddressHit } from '$lib/types';

	let { data } = $props();

	const isAddressQuery = $derived(looksLikeAddress(data.q));

	function mapHref(a: AddressHit) {
		const u = new URLSearchParams({ sel: a.entity_id });
		if (a.lon !== null && a.lat !== null) u.set('c', `${a.lon},${a.lat},17`);
		return `/?${u}`;
	}
	function externalMapHref(e: GeoAddressHit) {
		return `/?c=${e.lon},${e.lat},17&pin=1`;
	}
	function createAtHref(label: string, lat?: number, lon?: number) {
		const u = new URLSearchParams({ kind: 'building', name: label, address: label });
		if (lat !== undefined && lon !== undefined) {
			u.set('lat', String(lat));
			u.set('lon', String(lon));
		}
		return `/new?${u}`;
	}
	const createHref = $derived(
		isAddressQuery ? createAtHref(data.q) : `/new?slug=${slugifyClient(data.q)}`
	);
</script>

<svelte:head><title>Search: {data.q} · {data.settings.site_name}</title></svelte:head>

<div class="page narrow">
	<h1>Search</h1>
	<form method="get" class="row">
		<input name="q" value={data.q} placeholder="A building, street, business, person or address…" style="flex: 1" />
		<input type="hidden" name="go" value="0" />
		<button class="primary">Search</button>
	</form>
	<p class="small"><a href="/search/advanced{data.q ? `?q=${encodeURIComponent(data.q)}` : ''}">Advanced search →</a> filters by kind, years, condition, tags, facts, addresses, and what a page has or lacks.</p>
	<p class="hint">
		Matches current <em>and historic</em> names, and street addresses such as <code>577 Washington St</code>, so a
		building's old name still finds it.
	</p>

	{#if data.q && data.external.length}
		<!-- where the address is today: always here, however many results follow -->
		<div class="today">
			<span class="eyebrow">Today</span>
			<strong>{data.external[0].label}</strong>
			{#if data.external[0].locality}<span class="muted">· {data.external[0].locality}</span>{/if}
			<a href={externalMapHref(data.external[0])}>Show on the map →</a>
			{#if data.external.length > 1}<a class="muted small" href="#osm">{data.external.length - 1} more match{data.external.length === 2 ? '' : 'es'} ↓</a>{/if}
		</div>
	{/if}

	{#if data.q}
		<ul class="plain-list results">
			{#each data.hits as h (h.id)}
				<li>
					<a href="/e/{h.slug}"><strong>{h.name}</strong></a>
					{#if h.matched_name !== h.name}<span class="muted">· matched “{h.matched_name}”</span>{/if}
					<div class="row small">
						<KindBadge kind={h.kind} />
						{#if h.exists_from || h.exists_to}<span class="date">{yearOf(h.exists_from) ?? '?'} – {yearOf(h.exists_to) ?? ''}</span>{/if}
					</div>
				</li>
			{:else}
				<li class="muted">No pages match “{data.q}”.</li>
			{/each}
		</ul>

		{#if data.addresses.length}
			<h2>Addresses</h2>
			<ul class="plain-list results addresses">
				{#each data.addresses as a (a.address_id)}
					<li>
						<a href="/e/{a.entity_slug}"><strong>{a.formatted}</strong></a>
						{#if a.entity_name && a.entity_name.toLowerCase() !== a.formatted.toLowerCase()}
							<span class="muted">· {a.entity_name}</span>
						{/if}
						<div class="row small">
							<KindBadge kind={a.entity_kind} />
							{#if a.raw_address && a.street_name && a.raw_address !== a.formatted}
								<span class="muted">as written: {a.raw_address}</span>
							{/if}
							<a href={mapHref(a)}>Show on the map →</a>
						</div>
					</li>
				{/each}
			</ul>
		{/if}

		{#if data.external.length}
			<h2 id="osm">Where it is today (OpenStreetMap)</h2>
			<ul class="plain-list results addresses">
				{#each data.external as e (e.place_id)}
					<li>
						<strong>{e.label}</strong>
						{#if e.locality}<span class="muted">· {e.locality}</span>{/if}
						<div class="row small">
							<span class="badge">{e.known ? 'also in the wiki' : 'not yet a page'}</span>
							<a href={externalMapHref(e)}>Show on the map →</a>
							{#if data.user && !e.known}
								<a href={createAtHref(e.label, e.lat, e.lon)}>Create a page here →</a>
							{/if}
						</div>
					</li>
				{/each}
			</ul>
			<p class="hint">
				Geocoded from <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>.
				Use “Create a page here” to start an article at one of these addresses.
			</p>
		{/if}

		{#if data.user}
			<p><a class="btn" href={createHref}>{isAddressQuery ? `Create a page at “${data.q}”` : `Create “${data.q}”`}</a></p>
		{/if}
	{/if}
</div>

<style>
	.results {
		margin-top: 18px;
	}
	.results li {
		padding: 10px 0;
	}
	.addresses {
		margin-top: 8px;
	}
	.today {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		gap: 4px 10px;
		margin-top: 14px;
		padding: 10px 12px;
		border: 1px solid var(--line-2);
		border-left: 3px solid var(--sky);
		border-radius: var(--radius);
		background: var(--panel);
	}
	.today .eyebrow {
		color: var(--sky);
	}
	.badge {
		padding: 1px 7px;
		border: 1px solid var(--line-2);
		border-radius: 999px;
		font-size: 0.7rem;
		color: var(--muted);
	}
</style>
