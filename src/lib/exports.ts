/**
 * Ways to export a page, listed in its Export menu. To add one, add an entry
 * here and the route (or endpoint) its href points at.
 */
export interface ExportFormat {
	id: string;
	label: string;
	/** one line under the label in the menu */
	description: string;
	href: (slug: string) => string;
	/** open in a new tab (a page to print) rather than download */
	newTab?: boolean;
	/** only for these kinds of page (default: all) */
	kinds?: string[];
}

export const EXPORTS: ExportFormat[] = [
	{
		id: 'print',
		label: 'Printable page',
		description: 'Article, facts, timeline, shapes and sources on paper, or saved as a PDF',
		href: (slug) => `/e/${slug}/print`,
		newTab: true
	}
];

export const exportsFor = (kind: string) => EXPORTS.filter((x) => !x.kinds || x.kinds.includes(kind));
