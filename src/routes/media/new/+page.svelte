<script lang="ts">
	import { enhance } from '$app/forms';
	import { untrack } from 'svelte';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import GeometryPicker from '$lib/components/GeometryPicker.svelte';
	import TemporalFields from '$lib/components/TemporalFields.svelte';
	import TagSelect from '$lib/components/TagSelect.svelte';
	import { browserClient } from '$lib/supabaseBrowser';

	let { data, form } = $props();
	let busy = $state(false);
	let uploadError = $state<string | null>(null);
	let preview = $state<string | null>(null);
	let title = $state(untrack(() => data.title ?? ''));

	function pickFile(e: Event) {
		const f = (e.currentTarget as HTMLInputElement).files?.[0];
		if (preview) URL.revokeObjectURL(preview);
		preview = f && f.type.startsWith('image/') ? URL.createObjectURL(f) : null;
		if (f && !title) title = f.name.replace(/\.[^.]+$/, '').replace(/[_-]+/g, ' ');
	}
</script>

<svelte:head><title>Add media · {data.settings.site_name}</title></svelte:head>

<div class="page narrow">
	<h1>Add media</h1>
	<p class="muted">
		Photos, postcards, Sanborn sheets, clippings, video, oral-history audio. A media item has three times:
		when it was <strong>captured</strong>, the period it <strong>depicts</strong>, and when it was added here.
	</p>
	{#if form?.error}<p class="notice error">{form.error}</p>{/if}
	{#if uploadError}<p class="notice error">Upload failed: {uploadError}</p>{/if}

	<form
		method="post"
		enctype="multipart/form-data"
		class="stack"
		use:enhance={async ({ formData, cancel }) => {
			uploadError = null;
			const file = formData.get('file');
			formData.delete('file');
			if (file instanceof File && file.size > 0) {
				busy = true;
				const ext = file.name.includes('.') ? file.name.split('.').pop()!.toLowerCase() : 'bin';
				const path = `${new Date().getFullYear()}/${crypto.randomUUID()}.${ext}`;
				const { error } = await browserClient().storage.from('media').upload(path, file, {
					contentType: file.type || undefined,
					upsert: false
				});
				if (error) {
					busy = false;
					uploadError = error.message;
					cancel();
					return;
				}
				formData.set('storage_path', path);
				formData.set('mime_type', file.type);
			}
			busy = true;
			return async ({ update }) => {
				busy = false;
				await update({ reset: false });
			};
		}}
	>
		<div class="card">
			<div class="fields">
				<div style="grid-column: span 2">
					<label for="file">File</label>
					<input id="file" name="file" type="file" accept="image/*,video/*,audio/*,application/pdf" onchange={pickFile} />
				</div>
				<div>
					<label for="url">…or external URL</label>
					<input id="url" name="external_url" type="url" placeholder="https://" />
				</div>
			</div>
			{#if preview}<img class="preview" src={preview} alt="Preview" />{/if}
		</div>

		<div class="fields">
			<div style="grid-column: span 2">
				<label for="title">Title</label>
				<input id="title" name="title" bind:value={title} required placeholder="Main Street looking north from 7th Ave" />
			</div>
			<div>
				<label for="mt">Type</label>
				<select id="mt" name="media_type">
					{#each data.mediaTypes as t (t)}<option>{t}</option>{/each}
				</select>
			</div>
		</div>
		<div class="field">
			<label for="summary">Caption / description</label>
			<input id="summary" name="summary" />
		</div>
		<div class="fields">
			<div><label for="cap">Captured</label><input id="cap" name="captured" placeholder="1952 · c. 1950 · 1950s" /></div>
			<div><label for="cr">Creator</label><input id="cr" name="creator" /></div>
			<div><label for="rt">Rights / license</label><input id="rt" name="rights" placeholder="Public domain, CC BY 4.0, used with permission…" /></div>
		</div>

		<div>
			<label for="tags">Tags <span class="muted">(Ctrl/⌘-click for several)</span></label>
			<TagSelect id="tags" name="tags" multiple tags={data.tags} facets={['media_subject', 'topic', 'era', 'architecture']} />
		</div>

		<div class="card">
			<h3>What it shows</h3>
			<div class="field">
				<label for="dep">Depicts <span class="muted">(one or more pages)</span></label>
				<EntityPicker id="dep" name="depicts_id" multiple values={data.depicts} placeholder="Search for a page it shows…" />
			</div>
			<p class="hint">Add as many as the image shows. The depicted period defaults to the capture date; override it for e.g. a 1990s photo of a 1926 cornerstone.</p>
			<TemporalFields sources={data.sources} fromLabel="Depicts from" toLabel="Depicts until" idPrefix="dep" />
		</div>

		<div class="card">
			<h3>Where the camera stood <span class="muted small">(optional)</span></h3>
			<GeometryPicker mode="point" height={280} />
			<div class="fields" style="margin-top: 8px">
				<div><label for="bearing">Bearing (degrees, 0 = north)</label><input id="bearing" name="bearing" type="number" min="0" max="359" /></div>
			</div>
		</div>

		<button class="primary" disabled={busy}>{busy ? 'Saving…' : 'Add media'}</button>
	</form>
</div>

<style>
	.preview {
		max-width: 100%;
		max-height: 300px;
		margin-top: 10px;
		border-radius: var(--radius);
	}
	h3 {
		margin-top: 0;
	}
</style>
