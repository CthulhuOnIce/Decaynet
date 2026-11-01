<script lang="ts">
	import '../app.css';
	import { page } from '$app/state';
	import { enhance } from '$app/forms';

	let { data, children } = $props();

	const nav = [
		{ href: '/', label: 'Map' },
		{ href: '/browse', label: 'Browse' },
		{ href: '/timeline', label: 'Timeline' },
		{ href: '/tags', label: 'Tags' },
		{ href: '/changes', label: 'Changes' },
		{ href: '/maintenance', label: 'Maintenance' },
		{ href: '/sources', label: 'Sources' }
	];

	const isActive = (href: string) =>
		href === '/' ? page.url.pathname === '/' : page.url.pathname.startsWith(href);
</script>

<svelte:head>
	<title>Decaynet: Gary through time</title>
	<meta name="description" content="A time-machine map and regional wiki for Gary, Indiana." />
</svelte:head>

<header class="site-header">
	<a class="brand" href="/" aria-label="Decaynet home">
		<svg viewBox="0 0 32 32" width="24" height="24" aria-hidden="true">
			<path d="M6 25V12l5-4v17M13 25V6h6v19M21 25V14l5 3v8" fill="none" stroke="#c2562b" stroke-width="2.4" stroke-linejoin="round" />
			<path d="M4 25h24" stroke="#ece4d8" stroke-width="2" />
		</svg>
		<span>Decaynet</span>
	</a>

	<nav aria-label="Main">
		{#each nav as item (item.href)}
			<a href={item.href} class:active={isActive(item.href)}>{item.label}</a>
		{/each}
	</nav>

	<form class="search" action="/search" method="get" role="search">
		<input name="q" type="search" placeholder="Search names, past and present…" value={page.url.searchParams.get('q') ?? ''} aria-label="Search" />
	</form>

	<div class="account">
		{#if data.user}
			<a class="btn primary new" href="/new">+ New</a>
			<span class="who" title={data.profile?.role}>{data.profile?.display_name ?? data.user.email}</span>
			<form method="post" action="/logout" use:enhance>
				<button class="ghost">Sign out</button>
			</form>
		{:else}
			<a class="btn" href="/login?next={encodeURIComponent(page.url.pathname)}">Sign in</a>
		{/if}
	</div>
</header>

<main class:full={page.url.pathname === '/'}>
	{@render children()}
</main>

<style>
	.site-header {
		position: sticky;
		top: 0;
		z-index: 50;
		height: var(--header-h);
		display: flex;
		align-items: center;
		gap: 20px;
		padding: 0 16px;
		background: rgba(20, 17, 15, 0.94);
		backdrop-filter: blur(6px);
		border-bottom: 1px solid var(--line);
	}
	.brand {
		display: flex;
		align-items: center;
		gap: 8px;
		font-family: var(--serif);
		font-size: 1.2rem;
		font-weight: 700;
		color: var(--ink);
		letter-spacing: 0.01em;
	}
	.brand:hover {
		text-decoration: none;
	}
	nav {
		display: flex;
		gap: 2px;
	}
	nav a {
		color: var(--ink-2);
		padding: 6px 10px;
		border-radius: var(--radius);
		font-size: 0.9rem;
	}
	nav a:hover {
		background: var(--panel);
		text-decoration: none;
	}
	nav a.active {
		color: var(--ink);
		background: var(--panel-2);
	}
	.search {
		flex: 1;
		max-width: 340px;
		margin-left: auto;
	}
	.search input {
		padding: 6px 10px;
		font-size: 0.86rem;
	}
	.account {
		display: flex;
		align-items: center;
		gap: 10px;
	}
	.who {
		font-size: 0.85rem;
		color: var(--muted);
		max-width: 140px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.new {
		padding: 5px 10px;
	}
	main.full {
		height: calc(100vh - var(--header-h));
		overflow: hidden;
	}
	@media (max-width: 980px) {
		nav a:nth-child(n + 4) {
			display: none;
		}
		.who {
			display: none;
		}
	}
	@media (max-width: 640px) {
		.site-header {
			gap: 10px;
		}
		.brand span,
		.search {
			display: none;
		}
	}
</style>
