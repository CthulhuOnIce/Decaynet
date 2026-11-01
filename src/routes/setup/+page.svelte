<script lang="ts">
	import { untrack } from 'svelte';

	let { data, form } = $props();
	// Local, bound state: survives re-renders (e.g. the busy flag) and failed submissions
	let f = $state(
		untrack(() => ({ name: '', email: '', site_name: data.settings.site_name, region_name: '', tagline: data.settings.tagline }))
	);
	$effect.pre(() => {
		const vals = form?.values as Partial<typeof f> | undefined;
		if (vals) untrack(() => Object.assign(f, vals));
	});
	let busy = $state(false);
</script>

<svelte:head><title>Set up {data.settings.site_name}</title></svelte:head>

<div class="page narrow setup">
	<div class="eyebrow">First-time setup</div>
	<h1>Welcome to Decaynet</h1>
	<p class="muted">
		Create the administrator account and give your site a name. You'll set the region, map and everything else next.
	</p>
	{#if form?.error}<p class="notice error">{form.error}</p>{/if}

	<form method="post" class="stack" onsubmit={() => (busy = true)}>
		<!-- busy only changes the button label; inputs keep their bound values -->
		{#if data.needsCode}
			<section class="card">
				<h2>Setup code</h2>
				<p class="hint">
					Printed in the app's logs when it started (Portainer: <em>Containers → decaynet app → Logs</em>; CLI:
					<code>docker compose logs app</code>), or the <code>SETUP_TOKEN</code> you configured. It proves you run this server.
				</p>
				<input name="code" required autocomplete="off" placeholder="ABCD-EFGH-JKLM" class="code" aria-label="Setup code" />
			</section>
		{/if}

		<section class="card stack">
			<h2>1 · Administrator account</h2>
			<div class="fields">
				<div><label for="name">Your name</label><input id="name" name="name" required bind:value={f.name} autocomplete="name" /></div>
				<div><label for="email">Email</label><input id="email" name="email" type="email" required bind:value={f.email} autocomplete="email" /></div>
			</div>
			<div class="fields">
				<div><label for="pw">Password</label><input id="pw" name="password" type="password" minlength="8" required autocomplete="new-password" /></div>
				<div><label for="pw2">Confirm</label><input id="pw2" name="confirm" type="password" minlength="8" required autocomplete="new-password" /></div>
			</div>
		</section>

		<section class="card stack">
			<h2>2 · Your site</h2>
			<div class="fields">
				<div><label for="sn">Site name</label><input id="sn" name="site_name" bind:value={f.site_name} /></div>
				<div><label for="rn">Region</label><input id="rn" name="region_name" bind:value={f.region_name} placeholder="Detroit, Michigan · the world" /></div>
			</div>
			<div><label for="tl">Tagline</label><input id="tl" name="tagline" bind:value={f.tagline} /></div>
		</section>

		<div><button class="primary" aria-busy={busy}>{busy ? 'Setting up…' : 'Create admin & continue'}</button></div>
		<p class="hint">
			Prefer configuration? Set <code>ADMIN_EMAIL</code> and <code>ADMIN_PASSWORD</code> (optionally <code>ADMIN_NAME</code>)
			in the environment and restart: the admin is created automatically and this page is skipped.
		</p>
	</form>
</div>

<style>
	.setup {
		max-width: 680px;
	}
	h2 {
		margin-top: 0;
		font-size: 1.1rem;
	}
	.code {
		font-family: var(--mono);
		font-size: 1.2rem;
		letter-spacing: 0.12em;
		text-transform: uppercase;
		max-width: 260px;
	}
</style>
