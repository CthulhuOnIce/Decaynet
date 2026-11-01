<script lang="ts">
	import { enhance } from '$app/forms';
	import EntityPicker from '$lib/components/EntityPicker.svelte';
	import GeometryPicker from '$lib/components/GeometryPicker.svelte';

	let { data, form } = $props();
	const s = $derived(data.settings);
	let busy = $state(false);
	let showMap = $state(false);
	let previews = $state<string[]>([]);

	const scriptFor: Record<string, string> = {
		turnstile: 'https://challenges.cloudflare.com/turnstile/v0/api.js',
		hcaptcha: 'https://js.hcaptcha.com/1/api.js'
	};

	function pick(e: Event) {
		previews.forEach(URL.revokeObjectURL);
		const files = [...((e.currentTarget as HTMLInputElement).files ?? [])];
		previews = files.slice(0, s.tips_max_images).map((f) => URL.createObjectURL(f));
	}

	/** Shrink big photos in the browser before upload (keeps requests small). */
	async function downscale(file: File, maxDim = 2400, quality = 0.85): Promise<File> {
		if (!file.type.startsWith('image/') || file.type === 'image/gif' || file.size < 1.5 * 1024 * 1024) return file;
		try {
			const bmp = await createImageBitmap(file);
			const scale = Math.min(1, maxDim / Math.max(bmp.width, bmp.height));
			const canvas = document.createElement('canvas');
			canvas.width = Math.round(bmp.width * scale);
			canvas.height = Math.round(bmp.height * scale);
			canvas.getContext('2d')!.drawImage(bmp, 0, 0, canvas.width, canvas.height);
			const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, 'image/jpeg', quality));
			return blob ? new File([blob], file.name.replace(/\.[^.]+$/, '') + '.jpg', { type: 'image/jpeg' }) : file;
		} catch {
			return file;
		}
	}

	type CaptchaApi = { reset: () => void };
	const resetCaptcha = () => {
		const w = window as unknown as { turnstile?: CaptchaApi; hcaptcha?: CaptchaApi };
		w.turnstile?.reset();
		w.hcaptcha?.reset();
	};
</script>

<svelte:head>
	<title>Send a tip · {s.site_name}</title>
	{#if data.open && s.tips_captcha_provider !== 'none'}
		<script src={scriptFor[s.tips_captcha_provider]} async defer></script>
	{/if}
</svelte:head>

<div class="page narrow">
	<div class="eyebrow">Anonymous tip</div>
	<h1>Share what you know</h1>

	{#if !data.open}
		<p class="notice">Tips aren't being accepted right now.</p>
	{:else if form && 'ok' in form && form.ok}
		<div class="card thanks">
			<h2>Thank you.</h2>
			<p>An editor will review your tip. If you left contact details, they may get in touch.</p>
			<a class="btn" href="/tip">Send another</a>
			<a class="btn ghost" href="/">Back to the map</a>
		</div>
	{:else}
		<p class="intro">{s.tips_intro}</p>
		<p class="muted small privacy">
			No account needed. {#if s.tips_ip_mode === 'full'}Your IP address is recorded to deter abuse and is visible to editors.{:else if s.tips_ip_mode === 'hash'}A one-way hash of your IP address is kept only to limit spam; editors can't see your IP.{:else}Your IP address is not recorded.{/if}
		</p>
		{#if form && 'error' in form && form.error}<p class="notice error">{form.error}</p>{/if}

		<form
			method="post"
			enctype="multipart/form-data"
			class="stack"
			use:enhance={async ({ formData }) => {
				busy = true;
				const files = formData.getAll('images').filter((f): f is File => f instanceof File && f.size > 0);
				formData.delete('images');
				for (const f of files.slice(0, s.tips_max_images)) formData.append('images', await downscale(f));
				return async ({ update, result }) => {
					busy = false;
					if (result.type !== 'success') resetCaptcha();
					await update({ reset: result.type === 'success' });
				};
			}}
		>
			<div class="hp" aria-hidden="true">
				<label for="website_url">Leave this empty</label>
				<input id="website_url" name="website_url" tabindex="-1" autocomplete="off" />
			</div>

			<div><label for="subject">Subject <span class="muted">(optional)</span></label><input id="subject" name="subject" placeholder="The Palace's last show" /></div>

			<div class="fields">
				<div>
					<label for="about">About an existing page <span class="muted">(optional)</span></label>
					<EntityPicker id="about" name="about_entity_id" value={data.about} placeholder="Search places, people, businesses…" />
				</div>
				<div><label for="about_text">…or describe the place / person / business</label><input id="about_text" name="about_text" placeholder="Corner store at 15th & Grant" /></div>
			</div>

			<div>
				<label for="body">What do you know?</label>
				<textarea id="body" name="body" rows="8" required minlength="10" placeholder="Names, dates, what the place was like, what happened, how you know…"></textarea>
			</div>

			<div class="fields">
				<div><label for="when_text">When <span class="muted">(roughly)</span></label><input id="when_text" name="when_text" placeholder="around 1965, summer of '72" /></div>
				<div><label for="contact">Contact <span class="muted">(optional, private)</span></label><input id="contact" name="contact" placeholder="email or phone if you're happy to be contacted" /></div>
			</div>

			<div>
				{#if showMap}
					<div class="eyebrow">Where? Click the map to drop a pin</div>
					<GeometryPicker mode="point" height={280} />
				{:else}
					<button type="button" class="ghost" onclick={() => (showMap = true)}>+ Mark a location on the map</button>
				{/if}
			</div>

			{#if s.tips_allow_images && s.tips_max_images > 0}
				<div>
					<label for="images">Photos or scans <span class="muted">(up to {s.tips_max_images}, {s.tips_max_image_mb} MB each)</span></label>
					<input id="images" name="images" type="file" accept="image/*" multiple onchange={pick} />
					{#if previews.length}
						<div class="previews">{#each previews as p (p)}<img src={p} alt="" />{/each}</div>
					{/if}
					<p class="hint">Only send photos you took or have permission to share. Large photos are resized before sending.</p>
				</div>
			{/if}

			{#if s.tips_captcha_provider === 'turnstile'}
				<div class="cf-turnstile" data-sitekey={s.tips_captcha_site_key} data-theme="dark"></div>
			{:else if s.tips_captcha_provider === 'hcaptcha'}
				<div class="h-captcha" data-sitekey={s.tips_captcha_site_key} data-theme="dark"></div>
			{/if}

			<div><button class="primary" disabled={busy}>{busy ? 'Sending…' : 'Send tip'}</button></div>
		</form>
	{/if}
</div>

<style>
	.intro {
		font-size: 1.05rem;
		color: var(--ink-2);
	}
	.privacy {
		margin-top: -6px;
	}
	.hp {
		position: absolute;
		left: -10000px;
		width: 1px;
		height: 1px;
		overflow: hidden;
	}
	.previews {
		display: flex;
		gap: 6px;
		margin-top: 8px;
		flex-wrap: wrap;
	}
	.previews img {
		width: 90px;
		height: 70px;
		object-fit: cover;
		border-radius: 4px;
	}
	.thanks h2 {
		margin-top: 0;
	}
</style>
