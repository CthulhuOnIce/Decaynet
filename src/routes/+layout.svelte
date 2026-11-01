<script lang="ts">
	import '../app.css';
	import { page } from '$app/state';
	import { enhance } from '$app/forms';
	import { can } from '$lib/perms';

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

	const tools = $derived(
		[
			can('review_tips') && { href: '/tips', label: 'Tips', badge: data.openTips },
			(can('manage_layers') || can('bulk_edit') || can('edit_content')) && { href: '/workbench', label: 'Workbench' },
			(can('manage_users') || can('manage_settings')) && { href: '/admin', label: 'Admin' }
		].filter(Boolean) as { href: string; label: string; badge?: number }[]
	);
	let menuOpen = $state(false);

	const isActive = (href: string) =>
		href === '/' ? page.url.pathname === '/' : page.url.pathname.startsWith(href);
</script>

<svelte:head>
	<title>{data.settings.site_name}: {data.settings.tagline}</title>
	<meta name="description" content="A time-machine map and regional wiki for {data.settings.region_name}." />
</svelte:head>

<header class="site-header">
	<a class="brand" href="/" aria-label="Decaynet home">
		<svg viewBox="0 0 32 32" width="24" height="24" aria-hidden="true">
			<path d="M6 25V12l5-4v17M13 25V6h6v19M21 25V14l5 3v8" fill="none" stroke="#c2562b" stroke-width="2.4" stroke-linejoin="round" />
			<path d="M4 25h24" stroke="#ece4d8" stroke-width="2" />
		</svg>
		<span>{data.settings.site_name}</span>
	</a>

	<nav aria-label="Main">
		{#each nav as item (item.href)}
			<a href={item.href} class:active={isActive(item.href)}>{item.label}</a>
		{/each}
		{#each tools as item (item.href)}
			<a href={item.href} class="tool" class:active={isActive(item.href)}>
				{item.label}{#if item.badge}<span class="count">{item.badge}</span>{/if}
			</a>
		{/each}
	</nav>

	<form class="search" action="/search" method="get" role="search">
		<input name="q" type="search" placeholder="Search names, past and present…" value={page.url.searchParams.get('q') ?? ''} aria-label="Search" />
	</form>

	<div class="account">
		{#if data.settings.tips_enabled}
			<a class="btn ghost tip-link" href="/tip" title="Send an anonymous tip">Tip</a>
		{/if}
		{#if data.user}
			{#if can('edit_content')}<a class="btn primary new" href="/new">+ New</a>{/if}
			<div class="menu">
				<button class="ghost who" onclick={() => (menuOpen = !menuOpen)} aria-expanded={menuOpen} aria-haspopup="menu">
					{data.profile?.display_name ?? data.user.email} ▾
				</button>
				{#if menuOpen}
					<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
					<div class="dropdown" role="menu" tabindex="-1" onclick={() => (menuOpen = false)}>
						<div class="role muted small">{data.profile?.role}{data.profile?.suspended ? ' · suspended' : ''}</div>
						<a href="/account" role="menuitem">Account & profile</a>
						<a href="/u/{data.user.id}" role="menuitem">My contributions</a>
						<form method="post" action="/logout" use:enhance>
							<button class="ghost" role="menuitem">Sign out</button>
						</form>
					</div>
				{/if}
			</div>
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
		color: var(--ink-2);
		max-width: 180px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		border: 0;
	}
	.menu {
		position: relative;
	}
	.dropdown {
		position: absolute;
		right: 0;
		top: calc(100% + 6px);
		min-width: 200px;
		background: var(--panel-2);
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		padding: 6px;
		box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45);
		z-index: 60;
	}
	.dropdown a,
	.dropdown button {
		display: block;
		width: 100%;
		text-align: left;
		padding: 7px 10px;
		color: var(--ink);
		border-radius: 4px;
		border: 0;
	}
	.dropdown a:hover,
	.dropdown button:hover {
		background: var(--line);
		text-decoration: none;
	}
	.dropdown .role {
		padding: 4px 10px 6px;
		border-bottom: 1px solid var(--line);
		margin-bottom: 4px;
		text-transform: capitalize;
	}
	nav a.tool {
		color: var(--amber);
	}
	.count {
		display: inline-block;
		margin-left: 5px;
		min-width: 18px;
		padding: 0 5px;
		border-radius: 999px;
		background: var(--rust);
		color: #fff;
		font-size: 0.7rem;
		text-align: center;
	}
	.new {
		padding: 5px 10px;
	}
	main.full {
		height: calc(100vh - var(--header-h));
		overflow: hidden;
	}
	@media (max-width: 1180px) {
		nav a:nth-child(n + 4):not(.tool) {
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
