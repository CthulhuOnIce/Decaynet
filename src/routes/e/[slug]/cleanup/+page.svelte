<script lang="ts">
	import { enhance } from '$app/forms';
	import { formatRange } from '$lib/time';
	import { TIMELINE_SECTIONS, describeFix, fixChange, type TimelineSection } from '$lib/timelineCleanup';

	let { data, form } = $props();
	const e = $derived(data.entity);

	const actions = $derived(data.fixes.filter((f) => f.op !== 'note'));
	const notes = $derived(data.fixes.filter((f) => f.op === 'note'));
	const sections = $derived(
		(Object.keys(TIMELINE_SECTIONS) as TimelineSection[])
			.map((id) => ({ id, ...TIMELINE_SECTIONS[id], fixes: actions.filter((f) => f.section === id) }))
			.filter((s) => s.fixes.length)
	);
	const defaults = $derived(actions.filter((f) => f.default).map((f) => f.key));
	const suggestions = $derived(actions.length - defaults.length);
	// fixes start ticked, suggestions unticked; reset whenever a new plan arrives
	let picked = $state<string[]>([]);
	$effect.pre(() => {
		picked = defaults;
	});
	let busy = $state(false);
	const lifespan = $derived(formatRange(e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision) || 'no dates');
	const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
</script>

<svelte:head><title>Timeline cleanup · {e.name}</title></svelte:head>

<div class="page">
	<div class="eyebrow">Timeline cleanup</div>
	<h1><a href="/e/{e.slug}">{e.name}</a></h1>
	<p class="muted">
		Lifespan {lifespan}. These edits make the conditions, shapes, addresses and relations tell one continuous story within the
		lifespan. Nothing changes until you apply; every edit shows in the page's <a href="/e/{e.slug}/history">history</a>.
	</p>

	{#if form?.error}<p class="notice error">{form.error}</p>{/if}
	{#if form?.ok}<p class="notice ok">{form.ok}</p>{/if}

	<div class="grid-2">
		<div class="stack">
			{#if notes.length}
				<section class="card notes">
					<h3>Needs a person</h3>
					<ul class="plain-list">
						{#each notes as n (n.key)}
							<li>
								{describeFix(n)}
								{#if n.rule === 'rebuilt'}<a href="/e/{e.slug}/duplicate">Duplicate this page →</a>{/if}
							</li>
						{/each}
					</ul>
					<a class="small" href="/e/{e.slug}/facts">Edit facts by hand →</a>
				</section>
			{/if}

			{#if !actions.length}
				<div class="card">
					<h2>Nothing to fix</h2>
					<p class="muted">
						{notes.length
							? 'Everything that can be fixed automatically already agrees with the lifespan.'
							: 'The conditions, shapes, addresses and relations already agree with the lifespan.'}
					</p>
					<a class="btn" href="/e/{e.slug}">Back to the page</a>
				</div>
			{:else}
				<form
					method="post"
					action="?/apply"
					class="stack"
					use:enhance={() => {
						busy = true;
						return async ({ update }) => {
							await update();
							busy = false;
						};
					}}
				>
					<div class="spread">
						<h2>
							{plural(defaults.length, 'fix', 'fixes')}{#if suggestions}<span class="muted">, {plural(suggestions, 'suggestion')}</span>{/if}
						</h2>
						<span class="small">
							<button type="button" class="link" onclick={() => (picked = defaults)}>recommended</button> ·
							<button type="button" class="link" onclick={() => (picked = actions.map((f) => f.key))}>all</button> ·
							<button type="button" class="link" onclick={() => (picked = [])}>none</button>
						</span>
					</div>
					{#each sections as s (s.id)}
						<section class="card group">
							<h3>{s.title}</h3>
							<p class="hint">{s.why}</p>
							<ul class="plain-list">
								{#each s.fixes as f (f.key)}
									{@const change = fixChange(f)}
									<li class:suggestion={!f.default}>
										<label class="check">
											<input type="checkbox" name="key" value={f.key} bind:group={picked} />
											<span>
												{describeFix(f)}
												{#if !f.default}<span class="tag" title="Not ticked by default: check it against your sources">suggestion</span>{/if}
												{#if change}<span class="change mono">{change}</span>{/if}
											</span>
										</label>
									</li>
								{/each}
							</ul>
						</section>
					{/each}
					<p class="hint">
						Added conditions are marked “approximate” with a note saying they came from this cleanup. Check “Demolished” against
						what you know: a building that was moved or renamed rather than torn down needs a different condition.
					</p>
					<div class="row">
						<button class="primary" disabled={!picked.length || busy}>
							{busy ? 'Applying…' : `Apply ${plural(picked.length, 'edit')}`}
						</button>
						<a class="btn ghost" href="/e/{e.slug}">Cancel</a>
					</div>
				</form>
			{/if}
		</div>

		<aside class="stack">
			<div class="card">
				<h3>Conditions now</h3>
				<ul class="plain-list now">
					{#each data.states as s (s.id)}
						{@const ls = s.lifecycle_statuses as unknown as { label: string; color: string } | null}
						<li>
							<span class="dot" style:background={ls?.color ?? '#888'}></span>
							<strong>{ls?.label ?? s.status}</strong>
							<span class="muted small">{formatRange(s.valid_from, s.valid_from_precision, s.valid_to, s.valid_to_precision) || 'undated'}</span>
						</li>
					{:else}
						<li class="muted small">No conditions recorded.</li>
					{/each}
				</ul>
				<h3 class="gap">Shapes</h3>
				<ul class="plain-list now">
					{#each data.geoms as g (g.id)}
						<li>
							<strong>{g.role}</strong>
							<span class="muted small">{formatRange(g.valid_from, g.valid_from_precision, g.valid_to, g.valid_to_precision) || 'undated'}</span>
						</li>
					{:else}
						<li class="muted small">Not on the map.</li>
					{/each}
				</ul>
				{#if data.addresses.length}
					<h3 class="gap">Addresses</h3>
					<ul class="plain-list now">
						{#each data.addresses as a (a.id)}
							<li>
								<strong>{a.label}</strong>
								<span class="muted small">{formatRange(a.valid_from, a.valid_from_precision, a.valid_to, a.valid_to_precision) || 'undated'}</span>
							</li>
						{/each}
					</ul>
				{/if}
				<p class="small"><a href="/e/{e.slug}/facts">Edit facts by hand →</a></p>
			</div>
		</aside>
	</div>
</div>

<style>
	.group h3,
	.notes h3 {
		margin: 0;
	}
	.group .hint {
		margin: 2px 0 8px;
	}
	.group li + li,
	.notes li + li {
		margin-top: 6px;
	}
	.notes {
		border-color: var(--amber);
	}
	.notes ul {
		margin: 8px 0;
	}
	.check {
		display: flex;
		gap: 8px;
		align-items: flex-start;
		margin: 0;
		color: var(--ink);
		font-weight: normal;
	}
	.check input {
		margin-top: 3px;
	}
	.suggestion .check {
		color: var(--ink-2);
	}
	.tag {
		margin-left: 6px;
		padding: 0 6px;
		border: 1px dashed var(--amber);
		border-radius: 999px;
		font-size: 0.7rem;
		color: var(--amber);
		white-space: nowrap;
	}
	.change {
		display: block;
		font-size: 0.8rem;
		color: var(--ink-2);
	}
	h3.gap {
		margin-top: 14px;
	}
	.now li {
		display: flex;
		gap: 6px;
		align-items: baseline;
		flex-wrap: wrap;
		padding: 2px 0;
	}
	.dot {
		display: inline-block;
		width: 9px;
		height: 9px;
		border-radius: 50%;
		flex: none;
	}
	button.link {
		background: none;
		border: 0;
		padding: 0;
		color: var(--rust-2);
		font: inherit;
		cursor: pointer;
	}
</style>
