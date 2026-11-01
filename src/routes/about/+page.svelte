<script lang="ts">
	let { data } = $props();
	const s = $derived(data.settings);
</script>

<svelte:head><title>About · {s.site_name}</title></svelte:head>

<div class="page narrow">
	<div class="eyebrow">About</div>
	<h1>{s.site_name}</h1>
	<p class="lede">{s.tagline}</p>

	{#if data.aboutHtml}
		<div class="prose">{@html data.aboutHtml}</div>
	{:else}
		<div class="prose">
			<p>
				{s.site_name} is a time-machine map and community wiki for {s.region_name}. Every street, building, business,
				person, photo and event is a page, and every fact on it has a date, a confidence level and, ideally, a source.
				Drag the year slider on the <a href="/">map</a> to see what stood where, who occupied it, and what became of it.
			</p>
			<p>
				Anyone can read. Sign in to contribute, or <a href="/tip">send an anonymous tip</a> if you know something.
			</p>
		</div>
	{/if}

	<h2>Free software</h2>
	<div class="prose">
		<p>
			This site runs <strong>Decaynet</strong>, free software licensed under the
			<a href="https://www.gnu.org/licenses/agpl-3.0.html" rel="license noopener" target="_blank">GNU Affero General Public License v3.0 or later</a>.
			You can use, study, share and modify it. If you run a modified version for others over a network, you must offer them its source too.
		</p>
		<p><a class="btn" href={s.source_code_url} target="_blank" rel="noopener">Get the source code</a></p>
		<p class="muted small">
			Map data © OpenStreetMap contributors (ODbL) where the modern basemap is shown. Historical content is contributed
			by this site's community; check each page's sources.
		</p>
	</div>
</div>

<style>
	.lede {
		font-family: var(--serif);
		font-size: 1.2rem;
		color: var(--ink-2);
	}
</style>
