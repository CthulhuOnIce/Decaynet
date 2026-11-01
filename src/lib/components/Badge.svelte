<script lang="ts">
	let { color = '#968a7a', label, title = undefined }: { color?: string; label: string; title?: string } = $props();
</script>

<span class="badge" style:color {title}><span class="dot"></span>{label}</span>
