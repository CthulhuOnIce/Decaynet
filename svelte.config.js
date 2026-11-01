import adapter from '@sveltejs/adapter-node';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),
	kit: {
		// Node server output (build/), used by the Docker image. Swap the adapter
		// for Vercel / Netlify / Cloudflare if you prefer a serverless host.
		adapter: adapter({ out: 'build' })
	}
};

export default config;
