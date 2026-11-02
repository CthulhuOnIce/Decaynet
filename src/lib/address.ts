/** Does the query look like a street address? "577 Washington St" or "Hauptstraße 5". */
export function looksLikeAddress(q: string): boolean {
	return /^\s*\d+[a-z]?(?:-\d+)?\s+\S/i.test(q) || /\s\d+[a-z]?\s*$/i.test(q);
}
