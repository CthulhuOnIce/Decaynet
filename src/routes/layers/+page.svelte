<script lang="ts">
	import { enhance } from '$app/forms';

	let { data, form } = $props();
	const isMod = $derived(['moderator', 'admin'].includes(data.profile?.role ?? ''));
</script>

<svelte:head><title>Map overlays · Decaynet</title></svelte:head>

<div class="page">
	<h1>Historical map overlays</h1>
	<p class="muted" style="max-width: 75ch">
		Georeferenced rasters (Sanborn fire-insurance sheets, plat maps, USGS topos, aerial surveys) served as XYZ tiles.
		Georeference scans with a tool such as <a href="https://mapwarper.net" target="_blank" rel="noopener">Map Warper</a>
		or <a href="https://allmaps.org" target="_blank" rel="noopener">Allmaps</a>, then paste the tile URL here. On the
		map, overlays whose period covers the current year are marked with ●.
	</p>
	{#if form?.error}<p class="notice error">{form.error}</p>{/if}

	<table>
		<thead><tr><th>Overlay</th><th>Depicts</th><th>Zoom</th><th></th></tr></thead>
		<tbody>
			{#each data.layers as l (l.id)}
				<tr class:off={!l.enabled}>
					<td>
						<strong>{l.title}</strong>
						<div class="mono small muted">{l.tile_url}</div>
						{#if l.attribution}<div class="small muted">{l.attribution}</div>{/if}
					</td>
					<td class="date">{l.depicts_from?.slice(0, 4) ?? '?'} – {l.depicts_to?.slice(0, 4) ?? '?'}</td>
					<td class="mono">{l.min_zoom}–{l.max_zoom}</td>
					<td>
						{#if isMod}
							<div class="row">
								<form method="post" action="?/toggle" use:enhance>
									<input type="hidden" name="id" value={l.id} />
									<input type="hidden" name="enabled" value={String(!l.enabled)} />
									<button class="ghost">{l.enabled ? 'Disable' : 'Enable'}</button>
								</form>
								<form method="post" action="?/remove" use:enhance>
									<input type="hidden" name="id" value={l.id} />
									<button class="danger">Delete</button>
								</form>
							</div>
						{/if}
					</td>
				</tr>
			{:else}
				<tr><td colspan="4" class="muted">No overlays yet.</td></tr>
			{/each}
		</tbody>
	</table>

	{#if isMod}
		<form method="post" action="?/create" class="card stack add" use:enhance>
			<h3>Add overlay</h3>
			{#if form?.ok}<p class="notice ok">Added.</p>{/if}
			<div><label for="t">Title</label><input id="t" name="title" required placeholder="Sanborn, Gary, Vol. 1, 1925" /></div>
			<div><label for="u">Tile URL</label><input id="u" name="tile_url" required placeholder={'https://example.org/tiles/{z}/{x}/{y}.png'} /></div>
			<div class="fields">
				<div><label for="f">Depicts from</label><input id="f" name="depicts_from" placeholder="1925" /></div>
				<div><label for="to">Depicts until</label><input id="to" name="depicts_to" placeholder="1925 · 1950s" /></div>
				<div><label for="mn">Min zoom</label><input id="mn" name="min_zoom" type="number" value="10" /></div>
				<div><label for="mx">Max zoom</label><input id="mx" name="max_zoom" type="number" value="20" /></div>
				<div><label for="op">Default opacity</label><input id="op" name="default_opacity" type="number" step="0.05" min="0" max="1" value="0.75" /></div>
				<div><label for="ts">Tile size</label><input id="ts" name="tile_size" type="number" value="256" /></div>
			</div>
			<div><label for="b">Bounds (west,south,east,north)</label><input id="b" name="bounds" placeholder="-87.45,41.52,-87.22,41.64" /></div>
			<div><label for="a">Attribution</label><input id="a" name="attribution" placeholder="Library of Congress, Geography and Map Division" /></div>
			<button class="primary">Add overlay</button>
		</form>
	{:else}
		<p class="notice">Moderators can add overlays. Ask in the community, or post the tile URL on a page's talk notes.</p>
	{/if}
</div>

<style>
	tr.off {
		opacity: 0.5;
	}
	.add {
		margin-top: 24px;
		max-width: 720px;
	}
	.add h3 {
		margin-top: 0;
	}
</style>
