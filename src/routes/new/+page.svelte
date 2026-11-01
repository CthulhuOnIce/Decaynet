<script lang="ts">
	import GeometryPicker from '$lib/components/GeometryPicker.svelte';
	import { slugifyClient as autoSlug } from '$lib/slug';

	let { data, form } = $props();
	const v = $derived((form?.values ?? {}) as Record<string, string>);

	let kind = $state('building');
	let name = $state('');
	let slug = $state('');
	$effect.pre(() => {
		kind = v.kind ?? data.preset.kind;
		name = v.name ?? data.preset.name;
		slug = v.slug ?? data.preset.slug;
	});
	let slugTouched = $state(false);
	$effect(() => {
		if (!slugTouched && !data.preset.slug) slug = autoSlug(name);
	});
	const k = $derived(data.vocab.kinds.find((x) => x.id === kind));
</script>

<svelte:head><title>New page · Decaynet</title></svelte:head>

<div class="page narrow">
	<h1>New page</h1>
	<p class="muted">
		Create the entity first. Names, conditions, addresses, relations and shapes over time go on the next screen.
	</p>
	{#if form?.error}<p class="notice error">{form.error}</p>{/if}

	<form method="post" class="stack">
		<div class="kinds">
			{#each data.vocab.kinds as kk (kk.id)}
				<label class="kind" class:on={kind === kk.id} style:--c={kk.color}>
					<input type="radio" name="kind" value={kk.id} bind:group={kind} />
					{kk.label}
				</label>
			{/each}
		</div>
		{#if k?.description}<p class="hint">{k.description}</p>{/if}

		<div class="fields">
			<div style="grid-column: span 2">
				<label for="name">Name</label>
				<input id="name" name="name" bind:value={name} required placeholder="Palace Theater" />
			</div>
			<div>
				<label for="slug">Slug (URL)</label>
				<input id="slug" name="slug" bind:value={slug} oninput={() => (slugTouched = true)} pattern="[a-z0-9]+(-[a-z0-9]+)*" />
			</div>
		</div>
		<div class="field">
			<label for="summary">One-line summary</label>
			<input id="summary" name="summary" value={v.summary ?? ''} />
		</div>
		<div class="fields">
			<div>
				<label for="from">{k?.start_verb ?? 'Began'}</label>
				<input id="from" name="exists_from" placeholder="1926 · 1920s · c. 1926" value={v.exists_from ?? ''} />
			</div>
			<div>
				<label for="to">{k?.end_verb ?? 'Ended'}</label>
				<input id="to" name="exists_to" placeholder="blank = still exists" value={v.exists_to ?? ''} />
			</div>
			{#if kind === 'event'}
				<div>
					<label for="et">Event type</label>
					<select id="et" name="event_type">
						{#each data.vocab.eventTypes as t (t.id)}<option value={t.id}>{t.label}</option>{/each}
					</select>
				</div>
			{:else if ['building', 'site', 'street', 'infrastructure'].includes(kind)}
				<div>
					<label for="st">Initial condition</label>
					<select id="st" name="status">
						<option value="">(unknown)</option>
						{#each data.vocab.statuses as s (s.id)}<option value={s.id}>{s.label}</option>{/each}
					</select>
				</div>
			{/if}
		</div>

		{#if k?.geometry_hint || kind === 'event' || kind === 'media'}
			<div>
				<div class="eyebrow">Location (optional; refine later)</div>
				<GeometryPicker mode={k?.geometry_hint === 'line' ? 'line' : 'point'} height={300} />
			</div>
		{/if}

		<div class="row">
			<button class="primary">Create page</button>
			{#if kind === 'media'}<a href="/media/new">Uploading a file? Use the media uploader →</a>{/if}
		</div>
	</form>
</div>

<style>
	.kinds {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
	}
	.kind {
		display: inline-flex;
		align-items: center;
		margin: 0;
		padding: 6px 12px;
		border: 1px solid var(--line-2);
		border-radius: 999px;
		cursor: pointer;
		font-size: 0.88rem;
		color: var(--ink-2);
	}
	.kind input {
		display: none;
	}
	.kind.on {
		border-color: var(--c);
		color: var(--ink);
		background: color-mix(in srgb, var(--c) 22%, transparent);
	}
</style>
