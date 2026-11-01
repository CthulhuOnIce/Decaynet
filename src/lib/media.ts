import { env } from '$env/dynamic/public';

/** Public URL for a media item stored in Supabase Storage (or an external link). */
export function mediaSrc(storagePath: string | null | undefined, externalUrl?: string | null): string | null {
	if (storagePath) {
		const base = (env.PUBLIC_SUPABASE_URL ?? '').replace(/\/$/, '');
		return `${base}/storage/v1/object/public/media/${storagePath.split('/').map(encodeURIComponent).join('/')}`;
	}
	return externalUrl ?? null;
}

export const isImage = (mediaType: string) =>
	['photo', 'postcard', 'map', 'aerial', 'drawing', 'newspaper', 'document'].includes(mediaType);
