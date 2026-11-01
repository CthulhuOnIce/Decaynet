<script lang="ts">
	import { page } from '$app/state';
	import Badge from './Badge.svelte';

	let { kind }: { kind: string } = $props();
	const k = $derived(page.data.vocab?.kinds.find((x: { id: string }) => x.id === kind));
</script>

<Badge color={k?.color} label={k?.label ?? kind} />
