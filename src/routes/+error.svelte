<script lang="ts">
	import { page } from '$app/state';
	const slug = $derived(page.url.pathname.startsWith('/e/') ? page.url.pathname.split('/')[2] : null);
</script>

<div class="page narrow">
	<div class="eyebrow">{page.status}</div>
	<h1>{page.status === 404 ? 'Lost to time' : 'Something broke'}</h1>
	<p class="muted">{page.error?.message}</p>
	{#if page.status === 404 && slug}
		<p><a class="btn primary" href="/new?slug={slug}">Create “{slug}”</a></p>
	{/if}
	<p><a href="/">Back to the map</a></p>
</div>
