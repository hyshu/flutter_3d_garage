import 'dart:convert';

const plateauOrthophotoTileUrl =
    'https://tile.plateauview.mlit.go.jp/tiles/'
    'plateau-ortho-2023/{z}/{x}/{y}.png';
const openFreeMapTileJsonUrl = 'https://tiles.openfreemap.org/planet';
const openFreeMapGlyphsUrl =
    'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf';
const osmLabelsInitiallyVisible = false;
const osmLabelLayerIds = [
  'osm-place-label',
  'osm-road-label-major',
  'osm-road-label-minor',
  'osm-poi-label',
  'osm-poi-label-detail',
];

const _osmAttribution =
    '<a href="https://openfreemap.org/">OpenFreeMap</a> © '
    '<a href="https://openmaptiles.org/">OpenMapTiles</a> Data from '
    '<a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>';
const _osmTextField = [
  'coalesce',
  ['get', 'name_en'],
  ['get', 'name:latin'],
  ['get', 'name'],
  ['get', 'name:nonlatin'],
];
const _withinShinjukuArea = [
  'within',
  {
    'type': 'Polygon',
    'coordinates': [
      [
        [139.6848, 35.685],
        [139.7102, 35.685],
        [139.7102, 35.701],
        [139.6848, 35.701],
        [139.6848, 35.685],
      ],
    ],
  },
];
const _labelPaint = {
  'text-color': '#ffffff',
  'text-halo-color': '#242424',
  'text-halo-width': 2,
  'text-halo-blur': 0.5,
};
const _labelLayout = {
  'visibility': osmLabelsInitiallyVisible ? 'visible' : 'none',
  'text-field': _osmTextField,
  'text-font': ['Noto Sans Regular'],
  'text-pitch-alignment': 'viewport',
  'text-rotation-alignment': 'viewport',
};

String buildShinjukuStyle() => jsonEncode({
  'version': 8,
  'glyphs': openFreeMapGlyphsUrl,
  'sources': {
    'plateau-orthophoto': {
      'type': 'raster',
      'tiles': [plateauOrthophotoTileUrl],
      'tileSize': 256,
      'minzoom': 0,
      'maxzoom': 19,
      'attribution':
          '<a href="https://www.mlit.go.jp/plateau/">Project PLATEAU</a>',
    },
    'openmaptiles': {
      'type': 'vector',
      'url': openFreeMapTileJsonUrl,
      'attribution': _osmAttribution,
    },
  },
  'layers': [
    {
      'id': 'plateau-orthophoto',
      'type': 'raster',
      'source': 'plateau-orthophoto',
      'paint': {'raster-resampling': 'linear'},
    },
    {
      'id': 'osm-place-label',
      'type': 'symbol',
      'source': 'openmaptiles',
      'source-layer': 'place',
      'minzoom': 12,
      'filter': _withinShinjukuArea,
      'layout': {..._labelLayout, 'text-size': 14, 'text-max-width': 9},
      'paint': _labelPaint,
    },
    {
      'id': 'osm-road-label-major',
      'type': 'symbol',
      'source': 'openmaptiles',
      'source-layer': 'transportation_name',
      'minzoom': 13,
      'filter': [
        'all',
        _withinShinjukuArea,
        [
          'match',
          ['get', 'class'],
          ['primary', 'secondary', 'tertiary', 'trunk', 'motorway'],
          true,
          false,
        ],
      ],
      'layout': {..._labelLayout, 'symbol-placement': 'line', 'text-size': 13},
      'paint': _labelPaint,
    },
    {
      'id': 'osm-road-label-minor',
      'type': 'symbol',
      'source': 'openmaptiles',
      'source-layer': 'transportation_name',
      'minzoom': 17,
      'filter': [
        'all',
        _withinShinjukuArea,
        [
          'match',
          ['get', 'class'],
          ['minor', 'service', 'track'],
          true,
          false,
        ],
      ],
      'layout': {..._labelLayout, 'symbol-placement': 'line', 'text-size': 12},
      'paint': _labelPaint,
    },
    {
      'id': 'osm-poi-label',
      'type': 'symbol',
      'source': 'openmaptiles',
      'source-layer': 'poi',
      'minzoom': 15.5,
      'filter': [
        'all',
        _withinShinjukuArea,
        ['has', 'name'],
        [
          '<',
          ['get', 'rank'],
          7,
        ],
      ],
      'layout': {..._labelLayout, 'text-size': 12, 'text-max-width': 9},
      'paint': _labelPaint,
    },
    {
      'id': 'osm-poi-label-detail',
      'type': 'symbol',
      'source': 'openmaptiles',
      'source-layer': 'poi',
      'minzoom': 17,
      'filter': [
        'all',
        _withinShinjukuArea,
        ['has', 'name'],
        [
          '>=',
          ['get', 'rank'],
          7,
        ],
        [
          '<',
          ['get', 'rank'],
          20,
        ],
      ],
      'layout': {..._labelLayout, 'text-size': 11, 'text-max-width': 9},
      'paint': _labelPaint,
    },
  ],
});
