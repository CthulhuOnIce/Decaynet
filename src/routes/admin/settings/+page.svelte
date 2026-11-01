<script lang="ts">
	import { enhance } from '$app/forms';

	let { data, form } = $props();
	const s = $derived(data.settings);
	const msg = (k: string) => (form?.section === k ? form : null);
	let captcha = $state('none');
	$effect.pre(() => {
		captcha = s.tips_captcha_provider;
	});
</script>

<svelte:head><title>Site settings · Admin</title></svelte:head>

{#snippet status(k: string)}
	{@const m = msg(k)}
	{#if m && 'error' in m && m.error}<p class="notice error">{m.error}</p>{/if}
	{#if m && 'ok' in m && m.ok}<p class="notice ok">{m.ok}</p>{/if}
{/snippet}

<h1>Site settings</h1>
<p class="muted">Changes apply immediately for every visitor. Last saved {new Date(s.updated_at).toLocaleString()}.</p>
{@render status('settings')}

<form method="post" action="?/save" class="stack" use:enhance={() => async ({ update }) => update({ reset: false })}>
	<section class="card">
		<h2>Identity</h2>
		<div class="fields">
			<div><label for="sn">Site name</label><input id="sn" name="site_name" value={s.site_name} required /></div>
			<div><label for="tl">Tagline</label><input id="tl" name="tagline" value={s.tagline} /></div>
			<div><label for="rn">Region</label><input id="rn" name="region_name" value={s.region_name} /></div>
		</div>
		<div class="field">
			<label for="ab">About (Markdown)</label>
			<textarea id="ab" name="about" rows="4" style="min-height: 90px">{s.about}</textarea>
		</div>
	</section>

	<section class="card">
		<h2>Map</h2>
		<div class="fields">
			<div><label for="lon">Center longitude</label><input id="lon" name="map_center_lon" type="number" step="any" value={s.map_center_lon} /></div>
			<div><label for="lat">Center latitude</label><input id="lat" name="map_center_lat" type="number" step="any" value={s.map_center_lat} /></div>
			<div><label for="z">Zoom</label><input id="z" name="map_zoom" type="number" step="0.1" value={s.map_zoom} /></div>
			<div><label for="dy">Default year</label><input id="dy" name="default_year" type="number" value={s.default_year} /></div>
			<div><label for="my">Earliest year on slider</label><input id="my" name="min_year" type="number" value={s.min_year} /></div>
		</div>
		<div class="fields">
			<div style="grid-column: span 2">
				<label for="bu">Modern basemap tiles (XYZ)</label>
				<input id="bu" name="basemap_url" value={s.basemap_url} required />
				<p class="hint">Use your own or a paid tile provider in production; the public OSM server is for light use.</p>
			</div>
			<div>
				<label for="bm">Basemap behaviour</label>
				<select id="bm" name="basemap_mode">
					<option value="fade" selected={s.basemap_mode === 'fade'}>Fade as you go back in time</option>
					<option value="always" selected={s.basemap_mode === 'always'}>Always visible</option>
					<option value="hidden" selected={s.basemap_mode === 'hidden'}>Hidden (historical data only)</option>
				</select>
			</div>
		</div>
		<div class="field"><label for="ba">Basemap attribution (HTML)</label><input id="ba" name="basemap_attribution" value={s.basemap_attribution} /></div>
	</section>

	<section class="card">
		<h2>Accounts</h2>
		<label class="check"><input type="checkbox" name="allow_signups" checked={s.allow_signups} /> Allow new sign-ups</label>
		<p class="hint">
			When off, the sign-up form is hidden and anyone who still registers through the API gets the read-only role.
			To block registration entirely, also disable sign-ups in Supabase Auth settings.
		</p>
		<div class="fields">
			<div>
				<label for="dr">Role for new accounts</label>
				<select id="dr" name="default_role">
					{#each data.roles as r (r.id)}<option value={r.id} selected={s.default_role === r.id}>{r.label}</option>{/each}
				</select>
			</div>
		</div>
		<p class="hint"><a href="/admin/roles">Edit what each role can do →</a></p>
	</section>

	<section class="card">
		<h2>Anonymous tips</h2>
		{#if !data.hasServiceKey}
			<p class="notice error small">
				Tips need <code>SUPABASE_SERVICE_ROLE_KEY</code> set on the server: tips are written by the server after captcha and
				rate-limit checks, so guests can't bypass them. The tip form stays closed until it's set.
			</p>
		{/if}
		<label class="check"><input type="checkbox" name="tips_enabled" checked={s.tips_enabled} /> Accept tips at <a href="/tip">/tip</a></label>
		<div class="field">
			<label for="ti">Intro text on the tip page</label>
			<textarea id="ti" name="tips_intro" rows="3" style="min-height: 70px">{s.tips_intro}</textarea>
		</div>
		<div class="fields">
			<div>
				<label class="check"><input type="checkbox" name="tips_allow_images" checked={s.tips_allow_images} /> Allow images</label>
			</div>
			<div><label for="mi">Max images per tip</label><input id="mi" name="tips_max_images" type="number" min="0" max="20" value={s.tips_max_images} /></div>
			<div><label for="mb">Max image size (MB)</label><input id="mb" name="tips_max_image_mb" type="number" min="1" max="50" value={s.tips_max_image_mb} /></div>
			<div><label for="rl">Max tips per IP per hour</label><input id="rl" name="tips_rate_limit_per_hour" type="number" min="0" value={s.tips_rate_limit_per_hour} /></div>
		</div>
		<div class="fields">
			<div>
				<label for="ip">Source IP</label>
				<select id="ip" name="tips_ip_mode">
					<option value="off" selected={s.tips_ip_mode === 'off'}>Don't record (no rate limiting)</option>
					<option value="hash" selected={s.tips_ip_mode === 'hash'}>Salted hash only (rate limiting, no raw IP)</option>
					<option value="full" selected={s.tips_ip_mode === 'full'}>Full IP address (visible to tip reviewers)</option>
				</select>
				<p class="hint">Recording full IPs is personal data in many jurisdictions; say so in your privacy notice.</p>
			</div>
			<div>
				<label for="cp">Captcha</label>
				<select id="cp" name="tips_captcha_provider" bind:value={captcha}>
					<option value="none">None</option>
					<option value="turnstile">Cloudflare Turnstile</option>
					<option value="hcaptcha">hCaptcha</option>
				</select>
			</div>
			{#if captcha !== 'none'}
				<div><label for="ck">Captcha site key (public)</label><input id="ck" name="tips_captcha_site_key" value={s.tips_captcha_site_key ?? ''} /></div>
			{:else}
				<input type="hidden" name="tips_captcha_site_key" value={s.tips_captcha_site_key ?? ''} />
			{/if}
		</div>
	</section>

	<div><button class="primary">Save settings</button></div>
</form>

<section class="card secrets">
	<h2>Secrets</h2>
	<p class="muted small">Stored in a table only the server can read. Values are never shown again after saving.</p>
	{@render status('secret')}
	<form method="post" action="?/secret" class="row" use:enhance>
		<input type="hidden" name="key" value="tips_captcha_secret" />
		<label for="cs" style="margin: 0">Captcha secret key</label>
		<span class="badge" style:color={data.secrets.tips_captcha_secret ? 'var(--moss)' : 'var(--muted)'}>
			{data.secrets.tips_captcha_secret ? 'set' : 'not set'}
		</span>
		<input id="cs" name="value" type="password" autocomplete="off" placeholder="paste new secret" style="max-width: 300px" />
		<button>Save</button>
		{#if data.secrets.tips_captcha_secret}<button name="clear" value="1" class="danger">Clear</button>{/if}
	</form>
	<form method="post" action="?/secret" class="row" use:enhance style="margin-top: 10px">
		<input type="hidden" name="key" value="ip_hash_salt" />
		<label for="salt" style="margin: 0">IP hash salt</label>
		<span class="badge" style:color={data.secrets.ip_hash_salt ? 'var(--moss)' : 'var(--muted)'}>{data.secrets.ip_hash_salt ? 'set' : 'not set'}</span>
		<input id="salt" name="value" type="password" autocomplete="off" placeholder="rotate: paste a new random string" style="max-width: 300px" />
		<button>Rotate</button>
	</form>
</section>

<style>
	h2 {
		margin-top: 0;
	}
	.check {
		display: flex;
		gap: 8px;
		align-items: center;
		font-size: 0.92rem;
		color: var(--ink);
	}
	.secrets {
		margin-top: 24px;
	}
</style>
