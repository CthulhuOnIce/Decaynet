declare module '@cornerstonejs/codec-openjpeg/decodewasmjs' {
	/** Emscripten module factory for OpenJPEG's decoder (WebAssembly). */
	const factory: (options?: { locateFile?: (path: string) => string; print?: (s: string) => void; printErr?: (s: string) => void }) => Promise<unknown>;
	export default factory;
}
