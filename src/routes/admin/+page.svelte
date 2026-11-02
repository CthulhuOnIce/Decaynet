<script lang="ts">
	import { can } from '$lib/perms';

	let { data } = $props();
	const s = $derived(data.stats);

	interface Card {
		href: string;
		title: string;
		text: string;
		stat?: string | null;
		alert?: boolean;
	}
	const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

	const attention = $derived(
		[
			can('clean_timelines') &&
				s.timelines !== null && {
					href: '/admin/timelines',
					title: 'Timelines',
					text: 'Loose ends: no condition recorded, overlaps, tenants and addresses outliving a building, undated shapes.',
					stat: s.timelines ? plural(s.timelines, 'page') + ' to review' : 'All tidy',
					alert: !!s.timelines
				},
			can('review_tips') && {
				href: '/tips',
				title: 'Tips',
				text: 'Anonymous tips waiting for a reviewer.',
				stat: s.openTips ? `${s.openTips} open` : 'None open',
				alert: !!s.openTips
			},
			{
				href: '/maintenance',
				title: 'Maintenance',
				text: 'Pages missing citations, photos, dates or a place on the map.',
				stat: s.privatePages ? `${plural(s.privatePages, 'private page')} not yet published` : null
			}
		].filter(Boolean) as Card[]
	);
	const manage = $derived(
		[
			can('manage_users') && {
				href: '/admin/users',
				title: 'Users',
				text: 'Roles, suspensions and contact emails.',
				stat: s.users !== null ? `${plural(s.users ?? 0, 'account')}${s.suspended ? ` · ${s.suspended} suspended` : ''}` : null
			},
			can('manage_settings') && { href: '/admin/roles', title: 'Roles & permissions', text: 'What each role may do, including who can clean up timelines.' },
			can('moderate') && { href: '/admin/vocabulary', title: 'Vocabulary', text: 'Kinds, conditions, relation types and attributes.' },
			can('manage_settings') && { href: '/admin/settings', title: 'Site settings', text: 'Name, region and map, sign-ups, tips and captcha, secrets.' },
			can('bulk_edit') && {
				href: '/import',
				title: 'Imports',
				text: 'Starter pages from OpenHistoricalMap, Wikidata and more.',
				stat: s.imports ? `${plural(s.imports, 'import')} so far` : null
			}
		].filter(Boolean) as Card[]
	);
</script>

<svelte:head><title>Admin · {data.settings.site_name}</title></svelte:head>

<h1>Overview</h1>

{#snippet cards(list: Card[])}
	<div class="cards">
		{#each list as c (c.href)}
			<a class="card tile" class:alert={c.alert} href={c.href}>
				<strong>{c.title}</strong>
				<span class="muted small">{c.text}</span>
				{#if c.stat}<span class="stat">{c.stat}</span>{/if}
			</a>
		{/each}
	</div>
{/snippet}

{#if attention.length}
	<h2>Needs attention</h2>
	{@render cards(attention)}
{/if}
{#if manage.length}
	<h2>Manage</h2>
	{@render cards(manage)}
{/if}

<style>
	h2 {
		margin-top: 22px;
		font-size: 1.05rem;
	}
	.cards {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(230px, 1fr));
		gap: 12px;
	}
	.tile {
		display: grid;
		gap: 4px;
		align-content: start;
		color: inherit;
		text-decoration: none;
		transition: border-color 0.15s;
	}
	.tile:hover {
		border-color: var(--rust);
	}
	.tile strong {
		font-size: 1rem;
	}
	.stat {
		margin-top: 4px;
		font-size: 0.85rem;
		color: var(--ink-2);
	}
	.tile.alert .stat {
		color: var(--amber);
		font-weight: 600;
	}
</style>
