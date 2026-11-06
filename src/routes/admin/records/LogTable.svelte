<script lang="ts">
	import { FIELD_LABELS, TABLE_LABELS, changedFields, type LogRow } from '$lib/records';
	import { formatFuzzy, formatRange } from '$lib/time';

	let {
		rows,
		names,
		sources,
		tags,
		people = {},
		onrevert = undefined
	}: {
		rows: LogRow[];
		names: Record<string, { id: string; name: string; slug: string; kind: string }>;
		sources: Record<string, string>;
		tags: Record<string, string>;
		/** who made each change (the audit log shows it; a change set is one person's) */
		people?: Record<string, string>;
		/** take back one change */
		onrevert?: (r: LogRow) => void;
	} = $props();

	/** A value as people read it: page and source names, dates with their precision. */
	function show(k: string, v: unknown, d: Record<string, unknown> | null): string {
		if (v === null || v === undefined || v === '') return '—';
		if (['entity_id', 'subject_id', 'object_id', 'street_id'].includes(k)) return names[v as string]?.name ?? 'a deleted page';
		if (k === 'source_id') return sources[v as string] ?? 'a source';
		if (k === 'tag_id') return tags[v as string] ?? 'a tag';
		if ((k === 'valid_from' || k === 'valid_to' || k === 'exists_from' || k === 'exists_to') && typeof v === 'string')
			return formatFuzzy(v, ((d?.[`${k}_precision`] as string) ?? 'day') as never);
		if (typeof v === 'object') return JSON.stringify(v);
		return String(v);
	}

	/** What a row says, in a line: "vacant 1948–", "512 Broadway 1925–1930", "Kresge occupies …". */
	function gist(r: LogRow): string {
		const d = (r.new_data ?? r.old_data ?? {}) as Record<string, unknown>;
		const span = formatRange(d.valid_from as string, d.valid_from_precision as never, d.valid_to as string, d.valid_to_precision as never);
		const t = r.table_name;
		const what =
			t === 'entity_names'
				? `“${d.name}”`
				: t === 'entity_states'
					? String(d.status)
					: t === 'addresses'
						? `${d.house_number ?? ''} ${show('street_id', d.street_id, d)}${d.unit ? ` #${d.unit}` : ''}`.trim()
						: t === 'entity_attributes'
							? `${d.key}: ${typeof d.value === 'object' ? JSON.stringify(d.value) : d.value}`
							: t === 'entity_tags'
								? show('tag_id', d.tag_id, d)
								: t === 'relations'
									? `${show('subject_id', d.subject_id, d)} ${String(d.predicate).replace('_', ' ')} ${show('object_id', d.object_id, d)}`
									: t === 'entities'
										? `${d.name} (${d.kind})`
										: t === 'entity_geometries'
											? String(d.role ?? 'shape')
											: '';
		return [what, span, d.source_id ? `· ${show('source_id', d.source_id, d)}` : ''].filter(Boolean).join(' ');
	}
	const pageOf = (r: LogRow) => (r.entity_id ? names[r.entity_id] : null);
	const when = (d: string) => new Date(d).toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'short' });
</script>

<table class="log">
	<thead><tr><th>When</th>{#if Object.keys(people).length}<th>Who</th>{/if}<th>Page</th><th>What</th><th>Change</th>{#if onrevert}<th></th>{/if}</tr></thead>
	<tbody>
		{#each rows as r (r.id)}
			{@const p = pageOf(r)}
			<tr>
				<td class="small nowrap">{when(r.created_at)}</td>
				{#if Object.keys(people).length}<td class="small">{people[(r as LogRow & { actor_id?: string }).actor_id ?? ''] ?? '—'}</td>{/if}
				<td>{#if p}<a href="/e/{p.slug}">{p.name}</a>{:else}<span class="muted">deleted page</span>{/if}</td>
				<td class="small nowrap"><span class="op {r.op.toLowerCase()}">{r.op === 'INSERT' ? 'added' : r.op === 'DELETE' ? 'removed' : 'changed'}</span> {TABLE_LABELS[r.table_name] ?? r.table_name}</td>
				<td class="small">
					{#if r.op === 'UPDATE'}
						{#each changedFields(r) as [k, a, b] (k)}
							<div><span class="muted">{FIELD_LABELS[k] ?? k.replace(/_/g, ' ')}:</span> <del>{show(k, a, r.old_data)}</del> → <ins>{show(k, b, r.new_data)}</ins></div>
						{/each}
						<div class="muted">{gist(r)}</div>
					{:else}
						{gist(r)}
					{/if}
				</td>
				{#if onrevert}<td><button class="ghost tiny" onclick={() => onrevert(r)} title="Take this change back (in the open change set)">Take back</button></td>{/if}
			</tr>
		{/each}
	</tbody>
</table>

<style>
	.log td {
		vertical-align: top;
	}
	.nowrap {
		white-space: nowrap;
	}
	.op.insert {
		color: var(--moss);
	}
	.op.delete {
		color: var(--danger);
	}
	.op.update {
		color: var(--amber);
	}
	del {
		color: var(--muted);
	}
	ins {
		text-decoration: none;
		color: var(--ink);
	}
	.tiny {
		padding: 2px 8px;
		font-size: 0.8rem;
	}
</style>
