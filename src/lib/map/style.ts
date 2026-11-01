import type { ExpressionSpecification, LayerSpecification, StyleSpecification } from 'maplibre-gl';

export const GARY_CENTER: [number, number] = [-87.3366, 41.6005];
export const GARY_ZOOM = 13.6;

const GLYPHS = 'https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf';
export const FONT = ['Noto Sans Medium'];

/**
 * Modern OSM tiles, inverted into a dark, desaturated "present day" layer. The
 * time machine fades this layer out as you travel back so the historical data
 * dominates.
 */
export function baseStyle(settings?: { basemap_url?: string; basemap_attribution?: string } | null): StyleSpecification {
	return {
		version: 8,
		glyphs: GLYPHS,
		sources: {
			basemap: {
				type: 'raster',
				tiles: [settings?.basemap_url || 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
				tileSize: 256,
				maxzoom: 19,
				attribution:
					settings?.basemap_attribution ||
					'© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors'
			}
		},
		layers: [
			{ id: 'background', type: 'background', paint: { 'background-color': '#17130f' } },
			{
				id: 'basemap',
				type: 'raster',
				source: 'basemap',
				paint: {
					'raster-opacity': 0.6,
					'raster-saturation': -0.8,
					'raster-contrast': 0.1,
					'raster-brightness-min': 0.78,
					'raster-brightness-max': 0.07,
					'raster-opacity-transition': { duration: 400 }
				}
			}
		]
	};
}

const isPoly: ExpressionSpecification = ['==', ['geometry-type'], 'Polygon'];
const isLine: ExpressionSpecification = ['==', ['geometry-type'], 'LineString'];
const isPoint: ExpressionSpecification = ['==', ['geometry-type'], 'Point'];
const live: ExpressionSpecification = ['!=', ['get', 'ghost'], true];
const ghost: ExpressionSpecification = ['==', ['get', 'ghost'], true];
const selected: ExpressionSpecification = ['boolean', ['feature-state', 'selected'], false];
const notSpace: ExpressionSpecification = ['!=', ['get', 'kind'], 'space'];
const isSpace: ExpressionSpecification = ['==', ['get', 'kind'], 'space'];
const isNature: ExpressionSpecification = ['in', ['get', 'kind'], ['literal', ['water', 'landform']]];
const GHOST = '#8c8173';
const HILITE = '#f2c14e';

/** Layers that render a map_snapshot() FeatureCollection. */
export function snapshotLayers(source: string): LayerSpecification[] {
	return [
		{
			id: `${source}-district-fill`,
			type: 'fill',
			source,
			filter: ['all', isPoly, ['==', ['get', 'kind'], 'district']],
			paint: { 'fill-color': ['get', 'kind_color'], 'fill-opacity': 0.06 }
		},
		{
			id: `${source}-district-line`,
			type: 'line',
			source,
			filter: ['all', isPoly, ['==', ['get', 'kind'], 'district']],
			paint: {
				'line-color': ['case', selected, HILITE, ['get', 'kind_color']],
				'line-width': ['case', selected, 2.5, 1.2],
				'line-opacity': 0.7,
				'line-dasharray': [4, 3]
			}
		},
		{
			id: `${source}-ghost-area`,
			type: 'line',
			source,
			filter: ['all', isPoly, ghost],
			paint: { 'line-color': GHOST, 'line-width': 1.2, 'line-dasharray': [2, 2], 'line-opacity': 0.7 }
		},
		{
			id: `${source}-area-fill`,
			type: 'fill',
			source,
			filter: ['all', isPoly, live, ['!=', ['get', 'kind'], 'district'], notSpace],
			paint: {
				'fill-color': ['get', 'color'],
				'fill-opacity': ['case', selected, 0.65, isNature, 0.28, 0.38]
			}
		},
		{
			id: `${source}-area-line`,
			type: 'line',
			source,
			filter: ['all', isPoly, live, ['!=', ['get', 'kind'], 'district'], notSpace],
			paint: {
				'line-color': ['case', selected, HILITE, ['get', 'color']],
				'line-width': ['case', selected, 2.5, 1],
				'line-opacity': ['case', isNature, 0.5, 1]
			}
		},
		// Spaces (storefronts, suites, halls) inside building footprints, once zoomed in
		{
			id: `${source}-space-fill`,
			type: 'fill',
			source,
			minzoom: 16,
			filter: ['all', isPoly, live, isSpace],
			paint: {
				'fill-color': ['case', ['get', 'vacant_space'], '#3a312a', '#d9a46b'],
				'fill-opacity': ['case', selected, 0.85, 0.6]
			}
		},
		{
			id: `${source}-space-line`,
			type: 'line',
			source,
			minzoom: 16,
			filter: ['all', isPoly, isSpace],
			paint: {
				'line-color': ['case', selected, HILITE, '#f1dcc0'],
				'line-width': ['case', selected, 2.5, 0.8],
				'line-dasharray': [2, 1]
			}
		},
		{
			id: `${source}-space-label`,
			type: 'symbol',
			source,
			minzoom: 17,
			filter: ['all', isPoly, isSpace],
			layout: {
				'text-field': ['coalesce', ['get', 'tenant'], ['concat', ['get', 'name'], ' (vacant)']],
				'text-font': FONT,
				'text-size': 10.5,
				'text-max-width': 7
			},
			paint: { 'text-color': '#fff6e6', 'text-halo-color': '#17130f', 'text-halo-width': 1.4 }
		},
		{
			id: `${source}-ghost-line`,
			type: 'line',
			source,
			filter: ['all', isLine, ghost],
			paint: {
				'line-color': GHOST,
				'line-width': ['interpolate', ['linear'], ['zoom'], 12, 1, 17, 4],
				'line-dasharray': [1.5, 1.5],
				'line-opacity': 0.6
			}
		},
		{
			id: `${source}-line`,
			type: 'line',
			source,
			filter: ['all', isLine, live],
			layout: { 'line-cap': 'round', 'line-join': 'round' },
			paint: {
				'line-color': [
					'case',
					selected,
					HILITE,
					['==', ['get', 'kind'], 'street'],
					['case', ['get', 'extant'], '#d9c49a', GHOST],
					['get', 'color']
				],
				'line-width': ['interpolate', ['linear'], ['zoom'], 11, 1.2, 14, 3, 17, 9],
				'line-opacity': 0.9
			}
		},
		{
			id: `${source}-line-label`,
			type: 'symbol',
			source,
			minzoom: 13.5,
			filter: ['all', isLine],
			layout: {
				'symbol-placement': 'line',
				'text-field': ['get', 'name'],
				'text-font': FONT,
				'text-size': 11,
				'text-letter-spacing': 0.04
			},
			paint: { 'text-color': '#efe6d6', 'text-halo-color': '#17130f', 'text-halo-width': 1.6 }
		},
		{
			id: `${source}-ghost-point`,
			type: 'circle',
			source,
			filter: ['all', isPoint, ghost],
			paint: {
				'circle-radius': ['interpolate', ['linear'], ['zoom'], 11, 3, 16, 7],
				'circle-color': 'rgba(0,0,0,0)',
				'circle-stroke-color': ['case', selected, HILITE, GHOST],
				'circle-stroke-width': 1.5,
				'circle-stroke-opacity': 0.8
			}
		},
		{
			id: `${source}-point`,
			type: 'circle',
			source,
			filter: ['all', isPoint, live],
			paint: {
				'circle-radius': ['interpolate', ['linear'], ['zoom'], 11, ['case', selected, 6, 4], 16, ['case', selected, 11, 8]],
				'circle-color': ['get', 'color'],
				'circle-stroke-color': ['case', selected, HILITE, '#17130f'],
				'circle-stroke-width': ['case', selected, 3, 1.5],
				'circle-opacity': ['case', ['get', 'extant'], 1, 0.55]
			}
		},
		{
			id: `${source}-label`,
			type: 'symbol',
			source,
			minzoom: 14.2,
			filter: ['all', ['any', isPoint, isPoly], ['!=', ['get', 'kind'], 'district'], notSpace],
			layout: {
				'text-field': ['get', 'name'],
				'text-font': FONT,
				'text-size': 11.5,
				'text-anchor': 'top',
				'text-offset': [0, 0.9],
				'text-max-width': 9,
				'text-optional': true
			},
			paint: {
				'text-color': ['case', ['get', 'ghost'], GHOST, '#efe6d6'],
				'text-halo-color': '#17130f',
				'text-halo-width': 1.6
			}
		},
		{
			id: `${source}-district-label`,
			type: 'symbol',
			source,
			maxzoom: 15,
			filter: ['all', isPoly, ['==', ['get', 'kind'], 'district']],
			layout: {
				'text-field': ['upcase', ['get', 'name']],
				'text-font': FONT,
				'text-size': 11,
				'text-letter-spacing': 0.18
			},
			paint: { 'text-color': '#b9b4d0', 'text-halo-color': '#17130f', 'text-halo-width': 1.4, 'text-opacity': 0.75 }
		}
	];
}

/** Events and dated photos near the current year. */
export function momentLayers(source: string): LayerSpecification[] {
	return [
		{
			id: `${source}-halo`,
			type: 'circle',
			source,
			paint: {
				'circle-radius': ['interpolate', ['linear'], ['zoom'], 11, 10, 16, 18],
				'circle-color': ['get', 'color'],
				'circle-opacity': ['*', 0.22, ['get', 'nearness']],
				'circle-blur': 0.6
			}
		},
		{
			id: `${source}-dot`,
			type: 'circle',
			source,
			paint: {
				'circle-radius': ['interpolate', ['linear'], ['zoom'], 11, 4, 16, 7],
				'circle-color': ['get', 'color'],
				'circle-opacity': ['get', 'nearness'],
				'circle-stroke-color': '#fff',
				'circle-stroke-width': 1.2,
				'circle-stroke-opacity': ['get', 'nearness']
			}
		}
	];
}

/** Snapshot layers that respond to clicks / hovers. */
export const interactiveLayers = (source: string) =>
	[
		'district-fill',
		'space-fill',
		'area-fill',
		'ghost-area',
		'line',
		'ghost-line',
		'point',
		'ghost-point'
	].map((s) => `${source}-${s}`);

export function boundsOf(geojson: GeoJSON.Geometry | GeoJSON.FeatureCollection): [[number, number], [number, number]] | null {
	let w = Infinity, s = Infinity, e = -Infinity, n = -Infinity;
	const visit = (c: unknown): void => {
		if (Array.isArray(c) && typeof c[0] === 'number') {
			const [x, y] = c as number[];
			w = Math.min(w, x); e = Math.max(e, x); s = Math.min(s, y); n = Math.max(n, y);
		} else if (Array.isArray(c)) c.forEach(visit);
	};
	const geoms =
		geojson.type === 'FeatureCollection' ? geojson.features.map((f) => f.geometry) : [geojson];
	for (const g of geoms) if (g && 'coordinates' in g) visit(g.coordinates);
	return Number.isFinite(w) ? [[w, s], [e, n]] : null;
}
