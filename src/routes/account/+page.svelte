<script lang="ts">
	import { enhance } from '$app/forms';

	let { data, form } = $props();
	const msg = (s: string) => (form?.section === s ? form : null);
</script>

<svelte:head><title>Account · {data.settings.site_name}</title></svelte:head>

{#snippet status(s: string)}
	{@const m = msg(s)}
	{#if m && 'error' in m && m.error}<p class="notice error">{m.error}</p>{/if}
	{#if m && 'ok' in m && m.ok}<p class="notice ok">{m.ok}</p>{/if}
{/snippet}

<div class="page narrow stack">
	<h1>Your account</h1>
	{#if data.profile?.suspended}
		<p class="notice error">Your account is suspended. You can read the wiki but not edit it.</p>
	{/if}

	<form method="post" action="?/profile" class="card stack" use:enhance={() => async ({ update }) => update({ reset: false })}>
		<h2>Profile</h2>
		{@render status('profile')}
		<div><label for="dn">Display name</label><input id="dn" name="display_name" value={data.profile?.display_name ?? ''} required /></div>
		<div><label for="bio">Bio</label><textarea id="bio" name="bio" rows="3" style="min-height: 80px">{data.profile?.bio ?? ''}</textarea></div>
		<div><label for="web">Website</label><input id="web" name="website" type="url" value={data.profile?.website ?? ''} /></div>
		<div><button class="primary">Save profile</button> <a href="/u/{data.user?.id}">View public profile →</a></div>
	</form>

	<div class="card">
		<h2>Role & permissions</h2>
		<p>You are a <strong>{data.profile?.role}</strong>.</p>
		<ul class="plain-list">
			{#each data.permissions as p (p.id)}
				<li class="row">
					<span class:yes={data.perms.includes(p.id)} class="mark">{data.perms.includes(p.id) ? '✓' : '·'}</span>
					<span><strong>{p.label}</strong> <span class="muted small">{p.description}</span></span>
				</li>
			{/each}
		</ul>
	</div>

	<form method="post" action="?/email" class="card stack" use:enhance>
		<h2>Email</h2>
		{@render status('email')}
		<div><label for="em">Email address</label><input id="em" name="email" type="email" value={data.email ?? ''} required /></div>
		<div><button>Change email</button></div>
	</form>

	<form method="post" action="?/password" class="card stack" use:enhance>
		<h2>Password</h2>
		{@render status('password')}
		<div class="fields">
			<div><label for="pw">New password</label><input id="pw" name="password" type="password" minlength="8" autocomplete="new-password" required /></div>
			<div><label for="pw2">Confirm</label><input id="pw2" name="confirm" type="password" minlength="8" autocomplete="new-password" required /></div>
		</div>
		<div><button>Change password</button></div>
	</form>
</div>

<style>
	h2 {
		margin-top: 0;
	}
	.mark {
		width: 18px;
		color: var(--muted);
		font-family: var(--mono);
	}
	.mark.yes {
		color: var(--moss);
	}
</style>
