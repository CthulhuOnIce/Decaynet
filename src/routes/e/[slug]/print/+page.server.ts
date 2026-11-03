import { load as pageLoad } from '../+page.server';
import type { PageData as EntityPageData } from '../$types';
import type { PageServerLoad } from './$types';

/** Exactly what the page shows (the same year via ?y=), laid out for paper. */
export const load: PageServerLoad = async (event) => {
	const data = (await pageLoad(event as unknown as Parameters<typeof pageLoad>[0])) as EntityPageData;
	return { ...data, printedAt: new Date().toISOString(), pageUrl: `${event.url.origin}/e/${event.params.slug}` };
};
