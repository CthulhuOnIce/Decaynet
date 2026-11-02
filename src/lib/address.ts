/** Does the query look like a street address? "577 Washington St" or "Hauptstraße 5". */
export function looksLikeAddress(q: string): boolean {
	return /^\s*\d+[a-z]?(?:-\d+)?\s+\S/i.test(q) || /\s\d+[a-z]?\s*$/i.test(q);
}

/**
 * How an address reads (mirrors public.address_label in migration 0022):
 * number + street name when a street page is linked, otherwise the address as
 * written in the source, which already contains the number (added in front only
 * when it doesn't), otherwise the number alone.
 */
export function addressLabel(
	number: string | null | undefined,
	street: string | null | undefined,
	raw: string | null | undefined,
	format: 'number_street' | 'street_number' = 'number_street'
): string {
	const n = number?.trim() || '';
	const s = street?.trim() || '';
	const r = raw?.trim() || '';
	const join = (num: string, name: string) => (format === 'street_number' ? `${name} ${num}` : `${num} ${name}`).trim();
	if (s) return join(n, s);
	if (r) return n && !r.toLowerCase().includes(n.toLowerCase()) ? join(n, r) : r;
	return n;
}
