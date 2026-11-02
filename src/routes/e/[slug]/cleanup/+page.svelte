<script lang="ts">
	import { enhance } from '$app/forms';
	import { formatRange } from '$lib/time';
	import { TIMELINE_RULES, describeFix, fixChange, type TimelineRule } from '$lib/timelineCleanup';

	let { data, form } = $props();
	const e = $derived(data.entity);

	const groups = $derived(
		(Object.keys(TIMELINE_RULES) as TimelineRule[])
			.map((rule) => ({ rule, ...TIMELINE_RULES[rule], fixes: data.fixes.filter((f) => f.rule === rule) }))
			.filter((g) => g.fixes.length)
	);
	// every fix starts ticked; reset whenever a new plan arrives
	let picked = $state<string[]>([]);
	$effect.pre(() => {
		picked = data.fixes.map((f) => f.key);
	});
	let busy = $state(false);
	const lifespan = $derived(formatRange(e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision) || 'no dates');
</script>

<svelte:head><title>Timeline cleanup · {e.name}</title></svelte:head>

<div class="page">
	<div class="eyebrow">Timeline cleanup</div>
	<h1><a href="/e/{e.slug}">{e.name}</a></h1>
	<p class="muted">
		Lifespan {lifespan}. These fixes keep the conditions and footprint in step with the lifespan. Nothing is applied until you
		choose; every change shows in the page's <a href="/e/{e.slug}/history">history</a>.
	</p>

	{#if form?.error}<p class="notice error">{form.error}</p>{/if}
	{#if form?.ok}<p class="notice ok">{form.ok}</p>{/if}

	<div class="grid-2">
		<div>
			{#if !data.fixes.length}
				<div class="card">
					<h2>Nothing to fix</h2>
					<p class="muted">The conditions don't overlap or outlive the lifespan, and the footprint matches it.</p>
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
						<h2>{data.fixes.length} proposed fix{data.fixes.length === 1 ? '' : 'es'}</h2>
						<span class="small">
							<button type="button" class="link" onclick={() => (picked = data.fixes.map((f) => f.key))}>all</button> ·
							<button type="button" class="link" onclick={() => (picked = [])}>none</button>
						</span>
					</div>
					{#each groups as g (g.rule)}
						<section class="card group">
							<h3>{g.title}</h3>
							<p class="hint">{g.why}</p>
							<ul class="plain-list">
								{#each g.fixes as f (f.key)}
									{@const change = fixChange(f)}
									<li>
										<label class="check">
											<input type="checkbox" name="key" value={f.key} bind:group={picked} />
											<span>
												{describeFix(f)}
												{#if change}<span class="change mono">{change}</span>{/if}
											</span>
										</label>
									</li>
								{/each}
							</ul>
						</section>
					{/each}
					<p class="hint">
						Check “Record how it ended” against what you know: a building that was moved or renamed rather than torn down needs
						a different condition.
					</p>
					<div class="row">
						<button class="primary" disabled={!picked.length || busy}>
							{busy ? 'Applying…' : `Apply ${picked.length} fix${picked.length === 1 ? '' : 'es'}`}
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
				<p class="small"><a href="/e/{e.slug}/facts">Edit facts by hand →</a></p>
			</div>
		</aside>
	</div>
</div>

<style>
	.group h3 {
		margin: 0;
	}
	.group .hint {
		margin: 2px 0 8px;
	}
	.group li + li {
		margin-top: 6px;
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
