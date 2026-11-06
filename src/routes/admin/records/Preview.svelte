<script lang="ts">
	import { CONFLICTS, type ConflictRule, type WriteResult, type WriteSummary } from '$lib/records';

	let {
		title,
		summary,
		conflict,
		busy = false,
		onapply,
		onrecheck,
		oncancel
	}: {
		title: string;
		summary: WriteSummary;
		conflict: ConflictRule;
		busy?: boolean;
		onapply: () => void;
		/** check again with another rule for facts other sources back */
		onrecheck: (c: ConflictRule) => void;
		oncancel: () => void;
	} = $props();

	const ORDER = ['conflict', 'changed', 'cited', 'skipped', 'already'] as const;
	const LABEL: Record<string, string> = {
		changed: 'Will change',
		cited: 'Will cite (already so)',
		already: 'Already so',
		skipped: 'Skipped',
		conflict: 'Other sources say otherwise'
	};
	const groups = $derived(ORDER.map((o) => ({ o, rows: summary.items.filter((i) => i.outcome === o) })).filter((g) => g.rows.length));
	const doing = $derived(summary.changed + summary.cited);
	let open = $state<Record<string, boolean>>({ conflict: true, changed: true, skipped: true });
	const SHOW = 300;

	const line = (r: WriteResult) => (r.steps?.length ? r.steps.join('; ') : (r.reason ?? ''));
</script>

<div class="backdrop" role="presentation" onclick={oncancel}></div>
<div class="dialog" role="dialog" aria-modal="true" aria-label={title}>
	<div class="spread">
		<h2>{title}</h2>
		<button class="ghost icon-btn" onclick={oncancel} aria-label="Close">×</button>
	</div>
	<p class="counts small">
		{#each ORDER as o (o)}
			{#if summary[o]}<span class="c {o}">{summary[o]} {LABEL[o].toLowerCase()}</span>{/if}
		{/each}
	</p>
	{#if summary.conflict || conflict !== 'skip'}
		<label class="rule small">
			When another source's fact is in the way:
			<select value={conflict} onchange={(e) => onrecheck((e.currentTarget as HTMLSelectElement).value as ConflictRule)}>
				{#each CONFLICTS as c (c.id)}<option value={c.id}>{c.label}</option>{/each}
			</select>
		</label>
	{/if}
	<div class="list">
		{#each groups as g (g.o)}
			<details bind:open={open[g.o]}>
				<summary class="gh {g.o}">{LABEL[g.o]} · {g.rows.length}</summary>
				<ul>
					{#each g.rows.slice(0, SHOW) as r, i (i)}
						<li>
							<a href="/e/{r.slug}" target="_blank" rel="noopener">{r.name ?? 'page'}</a>
							{#if r.value_label && g.o !== 'skipped'}<span class="muted">· {r.value_label}{r.when ? `, ${r.when}` : ''}</span>{/if}
							<div class="small {g.o === 'changed' || g.o === 'cited' ? '' : 'muted'}">{line(r)}</div>
						</li>
					{/each}
					{#if g.rows.length > SHOW}<li class="muted small">and {g.rows.length - SHOW} more</li>{/if}
				</ul>
			</details>
		{/each}
	</div>
	<div class="spread foot">
		<span class="muted small">Nothing changes until you apply. It all goes in the open change set, and can be undone.</span>
		<span class="row">
			<button class="ghost" onclick={oncancel}>Cancel</button>
			<button class="primary" disabled={!doing || busy} onclick={onapply}>{busy ? 'Applying…' : doing ? `Apply ${doing}` : 'Nothing to apply'}</button>
		</span>
	</div>
</div>

<style>
	.backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.5);
		z-index: 60;
	}
	.dialog {
		position: fixed;
		z-index: 61;
		left: 50%;
		top: 6vh;
		transform: translateX(-50%);
		width: min(760px, calc(100vw - 32px));
		max-height: 88vh;
		display: flex;
		flex-direction: column;
		gap: 8px;
		background: var(--panel);
		border: 1px solid var(--line-2);
		border-radius: var(--radius);
		padding: 14px 16px;
	}
	h2 {
		font-size: 1.1rem;
		margin: 0;
	}
	.counts {
		display: flex;
		gap: 12px;
		flex-wrap: wrap;
		margin: 0;
	}
	.c.changed,
	.gh.changed {
		color: var(--moss);
	}
	.c.cited,
	.gh.cited {
		color: var(--sky);
	}
	.c.conflict,
	.gh.conflict {
		color: var(--amber);
	}
	.c.skipped,
	.c.already,
	.gh.skipped,
	.gh.already {
		color: var(--muted);
	}
	.rule {
		display: flex;
		gap: 8px;
		align-items: center;
		flex-wrap: wrap;
		margin: 0;
	}
	.rule select {
		width: auto;
	}
	.list {
		overflow: auto;
		border-top: 1px solid var(--line);
		border-bottom: 1px solid var(--line);
		padding: 6px 0;
	}
	summary {
		cursor: pointer;
		font-weight: 600;
		padding: 4px 0;
	}
	ul {
		list-style: none;
		margin: 0 0 8px;
		padding: 0;
	}
	li {
		padding: 4px 0 4px 14px;
		border-bottom: 1px dashed var(--line);
	}
	.foot {
		margin-top: 4px;
	}
</style>
