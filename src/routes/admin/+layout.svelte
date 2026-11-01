<script lang="ts">
	import { page } from '$app/state';
	import { can } from '$lib/perms';
	let { children } = $props();
	const links = $derived(
		[
			can('manage_settings') && { href: '/admin/settings', label: 'Site settings' },
			can('manage_users') && { href: '/admin/users', label: 'Users' },
			can('manage_settings') && { href: '/admin/roles', label: 'Roles & permissions' },
			can('moderate') && { href: '/admin/vocabulary', label: 'Vocabulary' }
		].filter(Boolean) as { href: string; label: string }[]
	);
</script>

<div class="page">
	<div class="eyebrow">Administration</div>
	<nav class="row tabs">
		{#each links as l (l.href)}
			<a class="btn" class:primary={page.url.pathname.startsWith(l.href)} href={l.href}>{l.label}</a>
		{/each}
	</nav>
	{@render children()}
</div>

<style>
	.tabs {
		margin: 8px 0 24px;
	}
</style>
