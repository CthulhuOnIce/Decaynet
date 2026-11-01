<script lang="ts">
	let { data, form } = $props();
	let mode = $state<'signin' | 'signup' | 'magic'>('signin');
	$effect.pre(() => {
		if (form?.mode) mode = form.mode as typeof mode;
	});
</script>

<svelte:head><title>Sign in · Decaynet</title></svelte:head>

<div class="page narrow auth">
	<h1>{mode === 'signup' ? 'Join the archive' : 'Sign in'}</h1>
	<p class="muted">Anyone can read. Contributors add places, dates, photos and stories about Gary.</p>

	<div class="row tabs">
		<button class:primary={mode === 'signin'} onclick={() => (mode = 'signin')}>Password</button>
		<button class:primary={mode === 'magic'} onclick={() => (mode = 'magic')}>Email link</button>
		{#if data.settings.allow_signups}
			<button class:primary={mode === 'signup'} onclick={() => (mode = 'signup')}>Create account</button>
		{/if}
	</div>

	{#if form?.error}<p class="notice error">{form.error}</p>{/if}
	{#if form && 'message' in form && form.message}<p class="notice ok">{form.message}</p>{/if}

	<form method="post" action="?/{mode}" class="card stack">
		<input type="hidden" name="next" value={data.next} />
		{#if mode === 'signup'}
			<div><label for="dn">Display name</label><input id="dn" name="display_name" required autocomplete="nickname" /></div>
		{/if}
		<div><label for="em">Email</label><input id="em" name="email" type="email" required autocomplete="email" value={form?.email ?? ''} /></div>
		{#if mode !== 'magic'}
			<div>
				<label for="pw">Password</label>
				<input id="pw" name="password" type="password" required minlength="8" autocomplete={mode === 'signup' ? 'new-password' : 'current-password'} />
			</div>
		{/if}
		<button class="primary">{mode === 'signup' ? 'Create account' : mode === 'magic' ? 'Email me a link' : 'Sign in'}</button>
		{#if mode === 'signup'}<p class="hint">The first account on a fresh install becomes the admin.</p>{/if}
	</form>
</div>

<style>
	.auth {
		max-width: 460px;
	}
	.tabs {
		margin: 18px 0 12px;
		gap: 6px;
	}
</style>
