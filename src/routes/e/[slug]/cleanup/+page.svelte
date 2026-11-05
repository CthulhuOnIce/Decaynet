<script lang="ts">
	import { enhance } from '$app/forms';
	import { formatRange } from '$lib/time';
	import { TIMELINE_SECTIONS, describeFix, fixChange, type TimelineSection } from '$lib/timelineCleanup';

	let { data, form } = $props();
	const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
	const e = $derived(data.entity);

	// ignored items stay out of the way until the page's timeline changes (then they come back on their own)
	const ignoredKeys = $derived(new Set(data.ignored));
	const ignored = $derived(data.fixes.filter((f) => ignoredKeys.has(f.key)));
	const live = $derived(data.fixes.filter((f) => !ignoredKeys.has(f.key)));
	const actions = $derived(live.filter((f) => f.op !== 'note'));
	const notes = $derived(live.filter((f) => f.op === 'note'));
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
	// storefronts, suites and halls inside it get their own default fixes after these
	const spaces = $derived(data.spaces);
	const spaceFixes = $derived(spaces.reduce((n, sp) => n + sp.keys.length, 0));
	const endsSpaces = $derived(picked.some((k) => actions.find((f) => f.key === k)?.section === 'spaces'));
	let withSpaces = $state(true);
	const willWork = $derived(picked.length > 0 || (withSpaces && spaces.length > 0));
	const applyLabel = $derived(
		[picked.length ? `Apply ${plural(picked.length, 'edit')}` : '', withSpaces && spaces.length ? `${picked.length ? 'tidy' : 'Tidy'} ${plural(spaces.length, 'space')}` : '']
			.filter(Boolean)
			.join(' and ') || 'Apply'
	);
	const lifespan = $derived(formatRange(e.exists_from, e.exists_from_precision, e.exists_to, e.exists_to_precision) || 'no dates');
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
							<li class="item">
								<span>
									{describeFix(n)}
									{#if n.rule === 'rebuilt'}<a href="/e/{e.slug}/duplicate">Duplicate this page →</a>{/if}
								</span>
								<form method="post" action="?/dismiss" use:enhance>
									<button class="ignore" name="dismiss" value={n.key} title="Wrong here: hide it until this page's timeline changes">Ignore</button>
								</form>
							</li>
						{/each}
					</ul>
					<a class="small" href="/e/{e.slug}/facts">Edit facts by hand →</a>
				</section>
			{/if}

			{#if !actions.length && !spaceFixes}
				<div class="card">
					<h2>Nothing to fix</h2>
					<p class="muted">
						{notes.length
							? 'Everything that can be fixed automatically already agrees with the lifespan.'
							: ignored.length
								? 'Everything left was ignored (below). It comes back if this page’s timeline changes.'
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
					{#if !actions.length}
						<h2>Nothing to fix on this page itself</h2>
						<p class="muted">Its interior spaces have {plural(spaceFixes, 'fix', 'fixes')} waiting.</p>
					{:else}
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
					{/if}
					{#each sections as s (s.id)}
						<section class="card group">
							<h3>{s.title}</h3>
							<p class="hint">{s.why}</p>
							<ul class="plain-list">
								{#each s.fixes as f (f.key)}
									{@const change = fixChange(f)}
									<li class="item" class:suggestion={!f.default}>
										<label class="check">
											<input type="checkbox" name="key" value={f.key} bind:group={picked} />
											<span>
												{describeFix(f)}
												{#if !f.default}<span class="tag" title="Not ticked by default: check it against your sources">suggestion</span>{/if}
												{#if change}<span class="change mono">{change}</span>{/if}
											</span>
										</label>
										<button
											class="ignore"
											formaction="?/dismiss"
											name="dismiss"
											value={f.key}
											title="Wrong here: hide it until this page's timeline changes">Ignore</button
										>
									</li>
								{/each}
							</ul>
						</section>
					{/each}
					{#if spaces.length}
						<section class="card group spaces-card">
							<label class="check">
								<input type="checkbox" name="spaces" value="1" bind:checked={withSpaces} />
								<span>
									<strong>Then tidy its {plural(spaces.length, 'interior space')}</strong>
									<span class="hint">
										Each space gets its own recommended fixes, after this page's, so its conditions, shapes and tenants fit the
										corrected lifespan. Spaces inside spaces too. Anything you ignored on a space stays ignored.
									</span>
								</span>
							</label>
							<ul class="plain-list space-list" class:off={!withSpaces}>
								{#each spaces as sp (sp.id)}
									<li style:padding-left="{(sp.depth - 1) * 1.1}em">
										<a href="/e/{sp.slug}/cleanup">{sp.name}</a>
										<span class="muted small">
											{sp.keys.length
												? plural(sp.keys.length, 'fix', 'fixes') + ' waiting'
												: endsSpaces
													? 'in order now; ending it may add some'
													: 'in order'}
										</span>
									</li>
								{/each}
							</ul>
						</section>
					{/if}
					<p class="hint">
						Added conditions are marked “approximate” with a note saying they came from this cleanup. Check “Demolished” against
						what you know: a building that was moved or renamed rather than torn down needs a different condition.
					</p>
					<div class="row">
						<button class="primary" disabled={!willWork || busy}>
							{busy ? 'Applying…' : applyLabel}
						</button>
						<button
							class="ghost"
							formaction="?/dismiss"
							disabled={!picked.length || busy}
							title="Hide the ticked items until this page's timeline changes">Ignore ticked</button
						>
						<a class="btn ghost" href="/e/{e.slug}">Cancel</a>
					</div>
				</form>
			{/if}

			{#if ignored.length}
				<details class="card ignored">
					<summary>
						{plural(ignored.length, 'ignored item')}
						<span class="muted small">· hidden until this page's timeline changes</span>
					</summary>
					<ul class="plain-list">
						{#each ignored as f (f.key)}
							<li class="item">
								<span class="muted">{describeFix(f)}</span>
								<form method="post" action="?/restore" use:enhance>
									<button class="ignore" name="restore" value={f.key}>Restore</button>
								</form>
							</li>
						{/each}
					</ul>
					{#if ignored.length > 1}
						<form method="post" action="?/restore" use:enhance><button class="ghost small">Restore all</button></form>
					{/if}
				</details>
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
	.spaces-card .check .hint {
		display: block;
		margin: 2px 0 0;
	}
	.space-list {
		margin: 8px 0 0 26px;
	}
	.space-list li {
		display: flex;
		gap: 8px;
		align-items: baseline;
		flex-wrap: wrap;
		padding: 1px 0;
	}
	.space-list.off {
		opacity: 0.5;
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
	.item {
		display: flex;
		gap: 10px;
		align-items: flex-start;
		justify-content: space-between;
	}
	.item > :first-child {
		flex: 1;
		min-width: 0;
	}
	.item form {
		margin: 0;
	}
	button.ignore {
		flex: none;
		padding: 1px 8px;
		font-size: 0.72rem;
		background: none;
		border: 1px solid var(--line-2);
		border-radius: 999px;
		color: var(--muted);
		cursor: pointer;
	}
	button.ignore:hover {
		color: var(--ink);
		border-color: var(--muted);
	}
	.ignored summary {
		cursor: pointer;
	}
	.ignored ul {
		margin: 10px 0;
	}
	.ignored li > span {
		font-size: 0.92rem;
	}
	.ignored li + li {
		margin-top: 6px;
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
