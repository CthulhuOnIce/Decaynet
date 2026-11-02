// @ts-expect-error: the project doesn't install @types/node; this only runs at build time
import { readdirSync } from 'node:fs';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

/** The newest migration this build of the app expects the database to have (e.g. "20261101000021"). */
const schemaVersion = (readdirSync(new URL('./supabase/migrations', import.meta.url)) as string[])
	.map((f: string) => /^(\d+)_.*\.sql$/.exec(f)?.[1])
	.filter((v): v is string => !!v)
	.sort()
	.at(-1) ?? '';

export default defineConfig({
	plugins: [sveltekit()],
	define: { __SCHEMA_VERSION__: JSON.stringify(schemaVersion) }
});
