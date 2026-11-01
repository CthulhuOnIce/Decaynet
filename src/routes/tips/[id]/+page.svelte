<script lang="ts">
	import { enhance } from '$app/forms';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import MiniMap from '$lib/components/MiniMap.svelte';
	import { can } from '$lib/perms';

	let { data, form } = $props();
	const t = $derived(data.tip);
	const STATUSES = ['new', 'reviewing', 'accepted', 'rejected', 'spam'];
	const kb = (n: number) => `${Math.round(n / 1024).toLocaleString()} KB`;
</script>

<svelte:head><title>Tip · {data.settings.site_name}</title></svelte:head>

<div class="page">
	<div class="eyebrow"><a href="/tips">Tips</a> · received {new Date(t.created_at).toLocaleString()}</div>
	<h1>{t.subject ?? 'Untitled tip'}</h1>
	{#if form && 'error' in form && form.error}<p class="notice error">{form.error}</p>{/if}
	{#if form && 'ok' in form && form.ok}
		<p class="notice ok">{form.ok} {#if 'mediaSlug' in form && form.mediaSlug}<a href="/e/{form.mediaSlug}">Open →</a>{/if}</p>
	{/if}

	<div class="grid-2">
		<div class="stack">
			<div class="card">
				<p class="body">{t.body}</p>
				<table class="meta">
					<tbody>
						{#if t.about_name}<tr><th>About</th><td><a href="/e/{t.about_slug}">{t.about_name}</a></td></tr>{/if}
						{#if t.about_text}<tr><th>Described as</th><td>{t.about_text}</td></tr>{/if}
						{#if t.when_text}<tr><th>When</th><td>{t.when_text}</td></tr>{/if}
						{#if t.contact}<tr><th>Contact</th><td>{t.contact}</td></tr>{/if}
						{#if t.resulting_name}<tr><th>Became</th><td><a href="/e/{t.resulting_slug}">{t.resulting_name}</a></td></tr>{/if}
					</tbody>
				</table>
			</div>

			{#if data.images.length}
				<h2>Images</h2>
				<div class="images">
					{#each data.images as img (img.path)}
						<div class="card img">
							{#if data.urls[img.path]}
								<a href={data.urls[img.path]} target="_blank" rel="noopener"><img src={data.urls[img.path]} alt={img.name} /></a>
							{/if}
							<div class="muted small">{img.name} · {kb(img.size)}</div>
							{#if can('upload_media')}
								<details>
									<summary class="small">Add to media library</summary>
									<form method="post" action="?/promote" class="stack" use:enhance>
										<input type="hidden" name="path" value={img.path} />
										<div><label for="tt-{img.path}">Title</label><input id="tt-{img.path}" name="title" value={t.subject ?? ''} /></div>
										<div class="fields">
											<div><label for="cap-{img.path}">Captured</label><input id="cap-{img.path}" name="captured" placeholder={t.when_text ?? 'c. 1960'} /></div>
											<div><label for="r-{img.path}">Rights</label><input id="r-{img.path}" name="rights" placeholder="Submitted anonymously; rights unverified" /></div>
										</div>
										<div>
											<label for="dep-{img.path}">Depicts</label>
											<EntityPicker id="dep-{img.path}" name="depicts_id" value={t.about_entity_id ? { id: t.about_entity_id, name: t.about_name } : null} />
										</div>
										<div><button>Add to media</button></div>
									</form>
								</details>
							{/if}
						</div>
					{/each}
				</div>
			{/if}
		</div>

		<aside class="stack">
			<form method="post" action="?/status" class="card stack" use:enhance={() => async ({ update }) => update({ reset: false })}>
				<div class="eyebrow">Review</div>
				<div class="row statuses">
					{#each STATUSES as s (s)}
						<label class="pill" class:on={t.status === s}><input type="radio" name="status" value={s} checked={t.status === s} />{s}</label>
					{/each}
				</div>
				<div><label for="notes">Reviewer notes</label><textarea id="notes" name="reviewer_notes" rows="3" style="min-height: 70px">{t.reviewer_notes ?? ''}</textarea></div>
				<div><button class="primary">Save</button></div>
				{#if t.reviewer_name}<p class="muted small">Last reviewed by {t.reviewer_name} · {new Date(t.reviewed_at).toLocaleString()}</p>{/if}
			</form>

			<div class="card stack">
				<div class="eyebrow">Fold into the wiki</div>
				<form method="post" action="?/link" class="stack" use:enhance>
					<div><label for="link">Link to an existing page</label><EntityPicker id="link" name="entity_id" value={t.about_entity_id ? { id: t.about_entity_id, name: t.about_name } : null} /></div>
					<div><button>Link & accept</button></div>
				</form>
				{#if can('edit_content')}
					<form method="post" action="?/create" class="stack">
						<div class="fields">
							<div><label for="nn">…or create a page</label><input id="nn" name="name" value={t.about_text ?? t.subject ?? ''} /></div>
							<div>
								<label for="nk">Kind</label>
								<select id="nk" name="kind">{#each data.vocab.kinds as k (k.id)}<option value={k.id} selected={k.id === 'building'}>{k.label}</option>{/each}</select>
							</div>
						</div>
						<div><button>Create page & accept</button></div>
					</form>
				{/if}
			</div>

			{#if t.location_geojson}
				<div class="card">
					<div class="eyebrow">Pinned location</div>
					<MiniMap features={[{ type: 'Feature', geometry: t.location_geojson, properties: { current: true } }]} height={220} />
				</div>
			{/if}

			<div class="card small">
				<div class="eyebrow">Source</div>
				<table class="meta">
					<tbody>
						<tr><th>IP</th><td class="mono">{t.ip_address ?? (t.ip_hash ? 'hashed (not stored)' : 'not recorded')}</td></tr>
						{#if t.ip_hash}<tr><th>Same source</th><td>{data.sameSource} tip{data.sameSource === 1 ? '' : 's'}</td></tr>{/if}
						<tr><th>Captcha</th><td>{t.captcha_verified ? 'verified' : 'not required'}</td></tr>
						{#if t.user_agent}<tr><th>Browser</th><td class="ua">{t.user_agent}</td></tr>{/if}
					</tbody>
				</table>
				{#if can('moderate')}
					<form
						method="post"
						action="?/delete"
						use:enhance={({ cancel }) => {
							if (!confirm('Delete this tip and its images permanently?')) cancel();
						}}
					>
						<button class="danger">Delete tip</button>
					</form>
				{/if}
			</div>
		</aside>
	</div>
</div>

<style>
	.body {
		white-space: pre-wrap;
		font-size: 1.02rem;
		line-height: 1.65;
		margin-top: 0;
	}
	.meta th {
		width: 110px;
		text-transform: none;
		letter-spacing: 0;
	}
	.images {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
		gap: 12px;
	}
	.img img {
		width: 100%;
		max-height: 260px;
		object-fit: contain;
		background: var(--bg-2);
		border-radius: 4px;
	}
	.statuses {
		gap: 4px;
	}
	.pill {
		display: inline-flex;
		margin: 0;
		padding: 4px 10px;
		border: 1px solid var(--line-2);
		border-radius: 999px;
		cursor: pointer;
		text-transform: capitalize;
	}
	.pill input {
		display: none;
	}
	.pill.on {
		background: var(--rust);
		border-color: var(--rust);
		color: #fff;
	}
	.ua {
		word-break: break-all;
		font-size: 0.75rem;
	}
</style>
