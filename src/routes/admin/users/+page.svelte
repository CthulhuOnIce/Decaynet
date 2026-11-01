<script lang="ts">
	import { enhance } from '$app/forms';
	let { data, form } = $props();
</script>

<svelte:head><title>Users · Admin</title></svelte:head>

<h1>Users</h1>
{#if !data.hasServiceKey}
	<p class="notice small">Set <code>SUPABASE_SERVICE_ROLE_KEY</code> on the server to see email addresses here.</p>
{/if}
{#if form?.error}<p class="notice error">{form.error}</p>{/if}
{#if form?.ok}<p class="notice ok">{form.ok}</p>{/if}

<form method="get" class="row filters">
	<input name="q" value={data.q} placeholder="Search display names" style="max-width: 280px" />
	<select name="role" style="max-width: 180px">
		<option value="">all roles</option>
		{#each data.roles as r (r.id)}<option value={r.id} selected={data.role === r.id}>{r.label}</option>{/each}
	</select>
	<button>Filter</button>
</form>

<table>
	<thead><tr><th>User</th><th>Role</th><th>Status</th><th>Joined</th></tr></thead>
	<tbody>
		{#each data.users as u (u.id)}
			<tr class:suspended={u.suspended}>
				<td>
					<a href="/u/{u.id}"><strong>{u.display_name}</strong></a>
					{#if data.emails[u.id]}<div class="muted small">{data.emails[u.id]}</div>{/if}
					{#if u.id === data.user?.id}<span class="muted small">(you)</span>{/if}
				</td>
				<td>
					<form method="post" action="?/setRole" use:enhance class="row">
						<input type="hidden" name="id" value={u.id} />
						<select name="role" onchange={(e) => e.currentTarget.form?.requestSubmit()} aria-label="Role for {u.display_name}">
							{#each data.roles as r (r.id)}<option value={r.id} selected={u.role === r.id}>{r.label}</option>{/each}
						</select>
					</form>
				</td>
				<td>
					<form method="post" action="?/suspend" use:enhance class="row">
						<input type="hidden" name="id" value={u.id} />
						<input type="hidden" name="suspended" value={String(!u.suspended)} />
						{#if u.suspended}
							<span class="muted small">Suspended{u.suspended_reason ? `: ${u.suspended_reason}` : ''}</span>
							<button class="ghost">Lift</button>
						{:else}
							<input name="reason" placeholder="reason" style="max-width: 140px" />
							<button class="danger">Suspend</button>
						{/if}
					</form>
				</td>
				<td class="date">{u.created_at.slice(0, 10)}</td>
			</tr>
		{/each}
	</tbody>
</table>

<style>
	.filters {
		margin-bottom: 14px;
	}
	tr.suspended {
		opacity: 0.6;
	}
	select {
		max-width: 170px;
	}
</style>
