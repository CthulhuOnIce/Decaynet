<script lang="ts">
	import '../app.css';
	import { page } from '$app/state';
	import { enhance } from '$app/forms';
	import { can, canAdmin } from '$lib/perms';

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
			(can('bulk_edit') || can('edit_content')) && { href: '/workbench', label: 'Workbench' },
			can('bulk_edit') && { href: '/import', label: 'Import' },
			canAdmin() && { href: '/admin', label: 'Admin' }
		].filter(Boolean) as { href: string; label: string; badge?: number }[]
	);
	let menuOpen = $state(false);
	let navOpen = $state(false);
	// Staff with several tools get one "Tools" menu instead of a row of links (keeps room for search)
	let toolsOpen = $state(false);
	const groupTools = $derived(tools.length > 1);
	const toolBadge = $derived(tools.reduce((n, t) => n + (t.badge ?? 0), 0));
	$effect(() => {
		page.url.pathname;
		navOpen = false;
		toolsOpen = false;
		menuOpen = false;
	});
	function closeMenus(e: Event) {
		if (e instanceof KeyboardEvent ? e.key !== 'Escape' : (e.target as HTMLElement).closest('.menu')) return;
		toolsOpen = false;
		menuOpen = false;
	}
	const fullBleed = $derived(page.url.pathname === '/' || page.url.pathname === '/workbench');

	const isActive = (href: string) =>
		href === '/' ? page.url.pathname === '/' : page.url.pathname.startsWith(href);
</script>

<svelte:head>
	<title>{data.settings.site_name}: {data.settings.tagline}</title>
	<meta name="description" content="A time-machine map and regional wiki for {data.settings.region_name}." />
</svelte:head>

<svelte:window onclick={closeMenus} onkeydown={closeMenus} />

<header class="site-header">
	<a class="brand" href="/" aria-label="Decaynet home">
		<svg viewBox="0 0 32 32" width="24" height="24" aria-hidden="true">
			<path d="M6 25V12l5-4v17M13 25V6h6v19M21 25V14l5 3v8" fill="none" stroke="#c2562b" stroke-width="2.4" stroke-linejoin="round" />
			<path d="M4 25h24" stroke="#ece4d8" stroke-width="2" />
		</svg>
		<span>{data.settings.site_name}</span>
	</a>

	<button class="burger ghost" onclick={() => (navOpen = !navOpen)} aria-expanded={navOpen} aria-controls="main-nav" aria-label="Toggle menu">
		<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
			{#if navOpen}<path d="M5 5l14 14M19 5L5 19" />{:else}<path d="M4 7h16M4 12h16M4 17h16" />{/if}
		</svg>
	</button>

	<nav id="main-nav" aria-label="Main" class:open={navOpen}>
		{#each nav as item (item.href)}
			<a href={item.href} class:active={isActive(item.href)}>{item.label}</a>
		{/each}
		{#each tools as item (item.href)}
			<a href={item.href} class="tool" class:grouped={groupTools} class:active={isActive(item.href)}>
				{item.label}{#if item.badge}<span class="count">{item.badge}</span>{/if}
			</a>
		{/each}
		{#if data.settings.tips_enabled}
			<a href="/tip" class="mobile-only" class:active={isActive('/tip')}>Send a tip</a>
		{/if}
	</nav>

	{#if groupTools}
		<div class="menu tools-menu">
			<button
				class="ghost tools-btn"
				class:active={tools.some((t) => isActive(t.href))}
				onclick={() => ((toolsOpen = !toolsOpen), (menuOpen = false))}
				aria-expanded={toolsOpen}
				aria-haspopup="menu"
			>
				Tools{#if toolBadge}<span class="count">{toolBadge}</span>{/if} ▾
			</button>
			{#if toolsOpen}
				<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
				<div class="dropdown from-left" role="menu" tabindex="-1" onclick={() => (toolsOpen = false)}>
					{#each tools as item (item.href)}
						<a href={item.href} role="menuitem" class:current={isActive(item.href)}>
							{item.label}{#if item.badge}<span class="count">{item.badge}</span>{/if}
						</a>
					{/each}
				</div>
			{/if}
		</div>
	{/if}

	<form class="search" action="/search" method="get" role="search">
		<input name="q" type="search" placeholder="Search names, addresses, past and present…" value={page.url.searchParams.get('q') ?? ''} aria-label="Search" />
	</form>

	<div class="account">
		{#if data.settings.tips_enabled}
			<a class="btn ghost tip-link" href="/tip" title="Send an anonymous tip">Tip</a>
		{/if}
		{#if data.user}
			{#if can('edit_content')}<a class="btn primary new" href="/new">+ New</a>{/if}
			<div class="menu">
				<button class="ghost who" onclick={() => ((menuOpen = !menuOpen), (toolsOpen = false))} aria-expanded={menuOpen} aria-haspopup="menu">
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

{#if !data.settings.setup_complete && can('manage_settings') && !page.url.pathname.startsWith('/admin')}
	<div class="setup">
		<strong>Welcome to your new {data.settings.site_name}.</strong>
		Set the site name, region, map area and timeline in <a href="/admin/settings">Site settings</a>, adjust the
		<a href="/admin/vocabulary">vocabulary</a> if your region needs it, then seed pages from
		<a href="/import">OpenHistoricalMap &amp; Wikidata</a>.
	</div>
{/if}

<main class:full={fullBleed}>
	{@render children()}
</main>

{#if !fullBleed}
	<footer class="site-footer">
		<span>{data.settings.site_name}</span>
		<a href="/about">About</a>
		{#if data.settings.tips_enabled}<a href="/tip">Send a tip</a>{/if}
		<span class="spacer"></span>
		<span>Free software under the <a href="https://www.gnu.org/licenses/agpl-3.0.html" rel="license noopener" target="_blank">GNU AGPL v3</a></span>
		<a href={data.settings.source_code_url} rel="noopener" target="_blank">Source code</a>
	</footer>
{/if}

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
	nav a.tool.grouped {
		display: none;
	}
	.tools-btn {
		font-size: 0.9rem;
		color: var(--amber);
		border: 0;
		padding: 6px 10px;
		white-space: nowrap;
	}
	.tools-btn.active {
		background: var(--panel-2);
	}
	.dropdown.from-left {
		left: 0;
		right: auto;
	}
	.dropdown a.current {
		background: var(--line);
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
	.setup {
		padding: 10px 20px;
		background: rgba(224, 162, 58, 0.14);
		border-bottom: 1px solid rgba(224, 162, 58, 0.4);
		font-size: 0.88rem;
	}
	.site-footer {
		display: flex;
		flex-wrap: wrap;
		gap: 16px;
		align-items: center;
		padding: 18px 24px 26px;
		border-top: 1px solid var(--line);
		font-size: 0.8rem;
		color: var(--muted);
	}
	.site-footer .spacer {
		flex: 1;
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
	nav a.mobile-only {
		display: none;
	}
	.burger {
		display: none;
		padding: 6px;
		border: 0;
		color: var(--ink);
	}
	.burger svg {
		fill: none;
		stroke: currentColor;
		stroke-width: 2;
		stroke-linecap: round;
		display: block;
	}
	@media (max-width: 640px) {
		.site-header {
			gap: 8px;
		}
		.brand span {
			display: none;
		}
		.burger {
			display: block;
		}
		.search {
			min-width: 0;
			flex: 1 1 0;
		}
		.search input {
			min-width: 0;
			width: 100%;
		}
		.tip-link {
			display: none;
		}
		nav {
			display: none;
		}
		.tools-menu {
			display: none;
		}
		nav.open {
			display: flex;
			flex-direction: column;
			gap: 0;
			position: absolute;
			top: 100%;
			left: 0;
			right: 0;
			padding: 8px;
			background: var(--bg, #14110f);
			border-bottom: 1px solid var(--line);
			max-height: calc(100vh - var(--header-h));
			overflow-y: auto;
		}
		nav.open a,
		nav.open a:nth-child(n + 4):not(.tool),
		nav.open a.tool.grouped,
		nav.open a.mobile-only {
			display: flex;
			justify-content: space-between;
			padding: 12px;
			font-size: 1rem;
		}
	}
</style>
