<script lang="ts">
	import { enhance } from '$app/forms';
	let { data, form } = $props();
</script>

<svelte:head><title>Roles & permissions · Admin</title></svelte:head>

<h1>Roles & permissions</h1>
<p class="muted">Tick a box to grant a permission to everyone with that role. Admins always have every permission. The database enforces these through row-level security.</p>
{#if form?.error}<p class="notice error">{form.error}</p>{/if}
{#if form?.ok}<p class="notice ok">{form.ok}</p>{/if}

<div class="scroll">
	<table class="matrix">
		<thead>
			<tr>
				<th>Permission</th>
				{#each data.roles as r (r.id)}
					<th class="c">
						{r.label}
						<div class="muted small">{data.counts[r.id] ?? 0} users</div>
						{#if !r.builtin}
							<form method="post" action="?/deleteRole" use:enhance>
								<input type="hidden" name="role" value={r.id} />
								<button class="danger" title="Delete role">delete</button>
							</form>
						{/if}
					</th>
				{/each}
			</tr>
		</thead>
		<tbody>
			{#each data.permissions as p (p.id)}
				<tr>
					<td><strong>{p.label}</strong><div class="muted small">{p.description}</div></td>
					{#each data.roles as r (r.id)}
						{@const on = r.id === 'admin' || data.grants.has(`${r.id}:${p.id}`)}
						<td class="c">
							<form method="post" action="?/toggle" use:enhance>
								<input type="hidden" name="role" value={r.id} />
								<input type="hidden" name="permission" value={p.id} />
								<input type="hidden" name="on" value={String(!on)} />
								<input
									type="checkbox"
									checked={on}
									disabled={r.id === 'admin'}
									onchange={(e) => e.currentTarget.form?.requestSubmit()}
									aria-label="{p.label} for {r.label}"
								/>
							</form>
						</td>
					{/each}
				</tr>
			{/each}
		</tbody>
	</table>
</div>

<form method="post" action="?/addRole" class="card stack add" use:enhance>
	<h3>New role</h3>
	<div class="fields">
		<div><label for="rl">Name</label><input id="rl" name="label" required placeholder="Archivist" /></div>
		<div><label for="rr">Rank</label><input id="rr" name="rank" type="number" value="15" /></div>
	</div>
	<div><label for="rd">Description</label><input id="rd" name="description" /></div>
	<div><button class="primary">Create role</button></div>
</form>

<style>
	.scroll {
		overflow-x: auto;
	}
	.matrix th.c,
	.matrix td.c {
		text-align: center;
		min-width: 100px;
	}
	.matrix th {
		text-transform: none;
		letter-spacing: 0;
		color: var(--ink);
		font-size: 0.85rem;
	}
	.add {
		margin-top: 24px;
		max-width: 520px;
	}
	.add h3 {
		margin-top: 0;
	}
</style>
