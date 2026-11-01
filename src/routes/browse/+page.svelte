<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import Badge from '$lib/components/Badge.svelte';
	import KindBadge from '$lib/components/KindBadge.svelte';
	import TagSelect from '$lib/components/TagSelect.svelte';
	import { formatRange } from '$lib/time';

	let { data } = $props();
	const statusOf = (id: string | null) => data.vocab.statuses.find((s) => s.id === id);
	const articleOf = (id: string | null) => data.vocab.articleStatuses.find((s) => s.id === id);

	function setFilter(key: string, value: string) {
		const u = new URL(page.url);
		if (value) u.searchParams.set(key, value);
		else u.searchParams.delete(key);
		u.searchParams.delete('page');
		goto(u, { keepFocus: true, noScroll: true });
	}
	const pageHref = (p: number) => {
		const u = new URL(page.url);
		u.searchParams.set('page', String(p));
		return u.pathname + u.search;
	};
</script>

<svelte:head><title>Browse · {data.settings.site_name}</title></svelte:head>

<div class="page">
	<div class="spread">
		<h1>Browse</h1>
		<span class="muted">{data.count.toLocaleString()} pages</span>
	</div>

	<div class="filters">
		<div class="chips">
			<button class:on={!data.filters.kind} onclick={() => setFilter('kind', '')}>All</button>
			{#each data.vocab.kinds as k (k.id)}
				<button class:on={data.filters.kind === k.id} style:--c={k.color} onclick={() => setFilter('kind', k.id)}>{k.plural}</button>
			{/each}
		</div>
		<div class="fields">
			<div>
				<label for="st">Condition today</label>
				<select id="st" value={data.filters.status} onchange={(e) => setFilter('status', e.currentTarget.value)}>
					<option value="">any</option>
					{#each data.vocab.statuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}
				</select>
			</div>
			<div>
				<label for="ar">Article status</label>
				<select id="ar" value={data.filters.article} onchange={(e) => setFilter('article', e.currentTarget.value)}>
					<option value="">any</option>
					{#each data.vocab.articleStatuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}
				</select>
			</div>
			<div onchange={(e) => setFilter('tag', (e.target as HTMLSelectElement).value)}>
				<label for="tg">Tag (incl. sub-traits)</label>
				<TagSelect id="tg" tags={data.tags} by="slug" value={data.filters.tag} placeholder="any" name="tag" />
			</div>
			<div>
				<label for="so">Sort</label>
				<select id="so" value={data.filters.sort} onchange={(e) => setFilter('sort', e.currentTarget.value)}>
					<option value="name">Name</option>
					<option value="oldest">Oldest first</option>
					<option value="recent">Recently edited</option>
				</select>
			</div>
		</div>
	</div>

	{#if data.error}<p class="notice error">{data.error}</p>{/if}

	<table>
		<thead><tr><th>Name</th><th>Kind</th><th>Dates</th><th>Today</th><th>Article</th></tr></thead>
		<tbody>
			{#each data.rows as r (r.id)}
				{@const st = statusOf(r.current_status)}
				{@const ar = articleOf(r.article_status)}
				<tr>
					<td>
						<a href="/e/{r.slug}"><strong>{r.name}</strong></a>
						{#if r.summary}<div class="muted small">{r.summary}</div>{/if}
					</td>
					<td><KindBadge kind={r.kind} /></td>
					<td class="date">{formatRange(r.exists_from, r.exists_from_precision, r.exists_to, r.exists_to_precision)}</td>
					<td>{#if st}<Badge color={st.color} label={st.label} />{/if}</td>
					<td>{#if ar}<Badge color={ar.color} label={ar.label} />{/if} <span class="muted small">{r.word_count ?? 0}w</span></td>
				</tr>
			{:else}
				<tr><td colspan="5" class="muted">Nothing matches.</td></tr>
			{/each}
		</tbody>
	</table>

	{#if data.pages > 1}
		<div class="row pager">
			{#if data.page > 1}<a class="btn" href={pageHref(data.page - 1)}>← Prev</a>{/if}
			<span class="muted">Page {data.page} of {data.pages}</span>
			{#if data.page < data.pages}<a class="btn" href={pageHref(data.page + 1)}>Next →</a>{/if}
		</div>
	{/if}
</div>

<style>
	.filters {
		margin: 12px 0 20px;
	}
	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		margin-bottom: 12px;
	}
	.chips button {
		border-radius: 999px;
		padding: 4px 12px;
		font-size: 0.84rem;
		--c: var(--muted);
	}
	.chips button.on {
		border-color: var(--c);
		background: color-mix(in srgb, var(--c) 22%, transparent);
	}
	.fields {
		max-width: 640px;
	}
	.pager {
		margin-top: 18px;
		justify-content: center;
	}
</style>
