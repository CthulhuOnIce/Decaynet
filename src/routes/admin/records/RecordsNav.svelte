<script lang="ts">
	import { page } from '$app/state';
	const links = [
		{ href: '/admin/records', label: 'Pages', exact: true },
		{ href: '/admin/records/facts', label: 'Each record' },
		{ href: '/admin/records/audit', label: 'Audit log' },
		{ href: '/admin/records/sets', label: 'Change sets' }
	];
	const on = (l: { href: string; exact?: boolean }) => (l.exact ? page.url.pathname === l.href : page.url.pathname.startsWith(l.href));
</script>

<nav class="sub" aria-label="Records">
	{#each links as l (l.href)}<a href={l.href} class:on={on(l)} aria-current={on(l) ? 'page' : undefined}>{l.label}</a>{/each}
</nav>

<style>
	.sub {
		display: flex;
		gap: 4px;
		flex-wrap: wrap;
		margin: -12px 0 14px;
	}
	.sub a {
		padding: 4px 12px;
		border-radius: 999px;
		color: var(--ink-2);
		text-decoration: none;
		font-size: 0.86rem;
		border: 1px solid transparent;
	}
	.sub a:hover {
		border-color: var(--line-2);
	}
	.sub a.on {
		background: var(--panel-2);
		border-color: var(--line-2);
		color: var(--ink);
	}
</style>
