import { Marked, type TokenizerAndRendererExtension, type Tokens } from 'marked';
import sanitizeHtml from 'sanitize-html';
import type { SupabaseClient } from '@supabase/supabase-js';

const WIKI_LINK = /\[\[([a-z0-9]+(?:-[a-z0-9]+)*)(?:\|([^\]]+))?\]\]/g;

const escapeHtml = (s: string) =>
	s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

/** All [[slug]] targets referenced by a body of markdown. */
export function extractWikiLinks(md: string): string[] {
	return [...new Set([...md.matchAll(WIKI_LINK)].map((m) => m[1]))];
}

interface WikiLinkToken extends Tokens.Generic {
	slug: string;
	label: string;
}

function makeRenderer(existing: Set<string>) {
	const wikiLink: TokenizerAndRendererExtension = {
		name: 'wikilink',
		level: 'inline',
		start: (src) => src.indexOf('[['),
		tokenizer(src) {
			const m = /^\[\[([a-z0-9]+(?:-[a-z0-9]+)*)(?:\|([^\]]+))?\]\]/.exec(src);
			if (m) return { type: 'wikilink', raw: m[0], slug: m[1], label: m[2] ?? m[1] } as WikiLinkToken;
		},
		renderer(token) {
			const t = token as WikiLinkToken;
			const missing = !existing.has(t.slug);
			// Red links point at the create form, like on any good wiki
			const href = missing ? `/new?slug=${t.slug}` : `/e/${t.slug}`;
			return `<a class="wikilink${missing ? ' redlink' : ''}" href="${href}">${escapeHtml(t.label)}</a>`;
		}
	};
	return new Marked({ gfm: true, breaks: false, extensions: [wikiLink] });
}

const SANITIZE: sanitizeHtml.IOptions = {
	allowedTags: sanitizeHtml.defaults.allowedTags.concat(['img', 'figure', 'figcaption', 'del', 'ins', 'sup', 'sub']),
	allowedAttributes: {
		a: ['href', 'class', 'title'],
		img: ['src', 'alt', 'title', 'width', 'height', 'loading'],
		'*': ['id']
	},
	allowedSchemes: ['http', 'https', 'mailto']
};

/** Render article markdown to safe HTML, marking links to missing pages as red links. */
export async function renderArticle(supabase: SupabaseClient, md: string): Promise<string> {
	const slugs = extractWikiLinks(md);
	let existing = new Set<string>();
	if (slugs.length) {
		const { data } = await supabase.from('entities').select('slug').in('slug', slugs);
		existing = new Set((data ?? []).map((r) => r.slug as string));
	}
	const html = await makeRenderer(existing).parse(md);
	return sanitizeHtml(html, SANITIZE);
}
