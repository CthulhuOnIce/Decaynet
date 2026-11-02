import { Marked, type TokenizerAndRendererExtension, type Tokens } from 'marked';
import sanitizeHtml from 'sanitize-html';
import type { SupabaseClient } from '@supabase/supabase-js';
import { extractCitations } from '$lib/sources';

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

interface CiteToken extends Tokens.Generic {
	id: string;
	detail: string;
}

/** How article citations render: footnote numbers and titles for the sources they point at. */
export interface CiteContext {
	number: Record<string, number>;
	title: Record<string, string>;
}

function makeRenderer(existing: Set<string>, cites: CiteContext = { number: {}, title: {} }) {
	// [cite:<source id>] or [cite:<source id>|p. 42] → a footnote reference like [3]
	const cite: TokenizerAndRendererExtension = {
		name: 'cite',
		level: 'inline',
		start: (src) => {
			const i = src.indexOf('[cite:');
			return i < 0 ? undefined : i;
		},
		tokenizer(src) {
			const m = /^\[cite:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\|([^\]\n]*))?\]/i.exec(src);
			if (m) return { type: 'cite', raw: m[0], id: m[1].toLowerCase(), detail: (m[2] ?? '').trim() } as CiteToken;
		},
		renderer(token) {
			const t = token as CiteToken;
			const n = cites.number[t.id];
			const title = cites.title[t.id];
			if (!n || !title) return `<sup class="cite missing" title="Source not found">[?]</sup>`;
			const tip = escapeHtml(t.detail ? `${title}, ${t.detail}` : title);
			return `<sup class="cite"><a href="#source-${n}" title="${tip}">[${n}]</a></sup>`;
		}
	};

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
	return new Marked({ gfm: true, breaks: false, extensions: [wikiLink, cite] });
}

const SANITIZE: sanitizeHtml.IOptions = {
	allowedTags: sanitizeHtml.defaults.allowedTags.concat(['img', 'figure', 'figcaption', 'del', 'ins', 'sup', 'sub']),
	allowedAttributes: {
		a: ['href', 'class', 'title'],
		sup: ['class', 'title'],
		img: ['src', 'alt', 'title', 'width', 'height', 'loading'],
		'*': ['id']
	},
	allowedSchemes: ['http', 'https', 'mailto']
};

/**
 * Render article markdown to safe HTML, marking links to missing pages as red
 * links. Citations are numbered by `numbering` (the page's footnote list) when
 * given, otherwise in order of first appearance (editor preview).
 */
export async function renderArticle(supabase: SupabaseClient, md: string, numbering?: Record<string, number>): Promise<string> {
	const slugs = extractWikiLinks(md);
	const citeIds = extractCitations(md);
	const [pages, cited] = await Promise.all([
		slugs.length ? supabase.from('entities').select('slug').in('slug', slugs) : Promise.resolve({ data: [] }),
		citeIds.length ? supabase.from('sources').select('id, title').in('id', citeIds) : Promise.resolve({ data: [] })
	]);
	const existing = new Set((pages.data ?? []).map((r) => r.slug as string));
	const title = Object.fromEntries(((cited.data ?? []) as { id: string; title: string }[]).map((s) => [s.id, s.title]));
	const number = numbering ?? Object.fromEntries(citeIds.filter((id) => title[id]).map((id, i) => [id, i + 1]));
	const html = await makeRenderer(existing, { number, title }).parse(md);
	return sanitizeHtml(html, SANITIZE);
}
