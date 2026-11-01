<script lang="ts">
	import type { TagRow } from '$lib/types';

	let {
		tags,
		name = 'tag_id',
		facets = null,
		multiple = false,
		value = undefined,
		id = undefined,
		required = false,
		placeholder = 'choose a tag…',
		by = 'id'
	}: {
		tags: TagRow[];
		name?: string;
		/** limit to these facets (null = all) */
		facets?: string[] | null;
		multiple?: boolean;
		value?: string | string[];
		id?: string;
		required?: boolean;
		placeholder?: string;
		/** submit tag ids or slugs */
		by?: 'id' | 'slug';
	} = $props();

	const groups = $derived.by(() => {
		const m = new Map<string, { label: string; rows: TagRow[] }>();
		for (const t of tags) {
			if (facets && !facets.includes(t.facet)) continue;
			if (!m.has(t.facet)) m.set(t.facet, { label: t.facet_label, rows: [] });
			m.get(t.facet)!.rows.push(t);
		}
		return [...m.values()];
	});
	const indent = (d: number) => '   '.repeat(d) + (d ? '└ ' : '');
	const isSel = (t: TagRow) => {
		const key = by === 'id' ? t.id : t.slug;
		return Array.isArray(value) ? value.includes(key) : value === key;
	};
</script>

<select {id} {name} {multiple} {required} size={multiple ? 8 : undefined}>
	{#if !multiple}<option value="">{placeholder}</option>{/if}
	{#each groups as g (g.label)}
		<optgroup label={g.label}>
			{#each g.rows as t (t.id)}
				<option value={by === 'id' ? t.id : t.slug} selected={isSel(t)}>{indent(t.depth)}{t.label}</option>
			{/each}
		</optgroup>
	{/each}
</select>
