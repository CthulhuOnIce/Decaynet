<script lang="ts">
	import { formatFuzzy, formatRange } from '$lib/time';
	let { data } = $props();
	const when = (d: string) => new Date(d).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
</script>

<svelte:head><title>Change sets · Records · Admin</title></svelte:head>

<div class="spread">
	<h1>Your change sets</h1>
	<a class="btn ghost" href="/admin/records">Back to Records</a>
</div>
<p class="muted">Everything you change in Records goes into the change set that's open: the year (or years), the source and how edits landed. Review one to see each change, before and after, or undo it as a whole.</p>

{#if data.sets.length}
	<table>
		<thead><tr><th>Set</th><th>Working in</th><th>Changes</th><th>Pages</th><th>Last change</th><th></th></tr></thead>
		<tbody>
			{#each data.sets as s (s.id)}
				<tr class:undone={!!s.undone_at}>
					<td><a href="/admin/records/sets/{s.id}">{s.title || 'Untitled'}</a></td>
					<td class="small">{s.context?.at ? (s.context.to ? formatRange(s.context.at, s.context.at_p as never, s.context.to, (s.context.to_p ?? 'year') as never) : formatFuzzy(s.context.at, s.context.at_p as never)) : '—'} · {s.context?.mode ?? ''}</td>
					<td>{s.changes}</td>
					<td>{s.pages}</td>
					<td class="small">{when(s.updated_at)}</td>
					<td class="small muted">{s.undone_at ? `undone ${when(s.undone_at)}` : ''}</td>
				</tr>
			{/each}
		</tbody>
	</table>
{:else}
	<p class="muted">None yet. Open <a href="/admin/records">Records</a>, set a year and a source, and start editing.</p>
{/if}

<style>
	tr.undone td {
		color: var(--muted);
		text-decoration: line-through;
	}
	tr.undone td:last-child {
		text-decoration: none;
	}
</style>
