<script lang="ts">
	import { page } from '$app/state';
	import { can } from '$lib/perms';
	let { children } = $props();
	const links = $derived(
		[
			{ href: '/admin', label: 'Overview', exact: true },
			can('manage_records') && { href: '/admin/records', label: 'Records' },
			can('clean_timelines') && { href: '/admin/timelines', label: 'Timelines' },
			can('manage_users') && { href: '/admin/users', label: 'Users' },
			can('manage_settings') && { href: '/admin/roles', label: 'Roles & permissions' },
			can('moderate') && { href: '/admin/vocabulary', label: 'Vocabulary' },
			can('manage_settings') && { href: '/admin/settings', label: 'Site settings' }
		].filter(Boolean) as { href: string; label: string; exact?: boolean }[]
	);
	const active = (l: { href: string; exact?: boolean }) => (l.exact ? page.url.pathname === l.href : page.url.pathname.startsWith(l.href));
</script>

<div class="page" class:wide={page.url.pathname.startsWith('/admin/records')}>
	<div class="eyebrow">Administration</div>
	<nav class="tabs" aria-label="Administration">
		{#each links as l (l.href)}
			<a href={l.href} class:on={active(l)} aria-current={active(l) ? 'page' : undefined}>{l.label}</a>
		{/each}
	</nav>
	{@render children()}
</div>

<style>
	.page.wide {
		max-width: none;
		padding-left: 16px;
		padding-right: 16px;
	}
	.tabs {
		display: flex;
		flex-wrap: wrap;
		gap: 2px 18px;
		margin: 6px 0 24px;
		border-bottom: 1px solid var(--line);
	}
	.tabs a {
		padding: 8px 0;
		margin-bottom: -1px;
		border-bottom: 2px solid transparent;
		color: var(--ink-2);
		text-decoration: none;
		font-size: 0.92rem;
	}
	.tabs a:hover {
		color: var(--ink);
	}
	.tabs a.on {
		color: var(--ink);
		border-bottom-color: var(--rust);
	}
</style>
