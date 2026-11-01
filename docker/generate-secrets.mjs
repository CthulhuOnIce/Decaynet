#!/usr/bin/env node
// Generate fresh secrets for the bundled Supabase stack and print them as .env lines.
//   node docker/generate-secrets.mjs >> .env
//   docker run --rm -v "$PWD":/w node:22-alpine node /w/docker/generate-secrets.mjs >> .env
// SPDX-License-Identifier: AGPL-3.0-or-later
import { createHmac, randomBytes } from 'node:crypto';

const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
const sign = (payload, secret) => {
	const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
	const body = b64url(JSON.stringify(payload));
	const sig = b64url(createHmac('sha256', secret).update(`${head}.${body}`).digest());
	return `${head}.${body}.${sig}`;
};

const jwtSecret = randomBytes(40).toString('hex');
const iat = Math.floor(Date.now() / 1000);
const exp = iat + 10 * 365 * 24 * 3600; // 10 years

console.log(`# --- generated ${new Date().toISOString()} by docker/generate-secrets.mjs ---`);
console.log(`POSTGRES_PASSWORD=${randomBytes(24).toString('hex')}`);
console.log(`JWT_SECRET=${jwtSecret}`);
console.log(`ANON_KEY=${sign({ role: 'anon', iss: 'supabase', iat, exp }, jwtSecret)}`);
console.log(`SERVICE_ROLE_KEY=${sign({ role: 'service_role', iss: 'supabase', iat, exp }, jwtSecret)}`);
