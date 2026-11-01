<script lang="ts">
	import type { Confidence } from '$lib/types';
	let { confidence }: { confidence: Confidence } = $props();

	const marks: Record<Confidence, { sym: string; text: string; color: string }> = {
		confirmed: { sym: '✓', text: 'Confirmed by a reliable source', color: '#7fae6a' },
		probable: { sym: '', text: 'Probable', color: '' },
		approximate: { sym: '≈', text: 'Approximate', color: '#c9b04f' },
		speculative: { sym: '?', text: 'Speculative: needs verification', color: '#d07a3a' },
		disputed: { sym: '⚑', text: 'Disputed', color: '#e0552b' }
	};
	const m = $derived(marks[confidence]);
</script>

{#if m.sym}
	<span class="conf" style:color={m.color} title={m.text} aria-label={m.text}>{m.sym}</span>
{/if}

<style>
	.conf {
		font-family: var(--mono);
		font-size: 0.8rem;
		margin-left: 3px;
		cursor: help;
	}
</style>
