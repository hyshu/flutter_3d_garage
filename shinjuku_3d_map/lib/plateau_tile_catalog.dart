import 'dart:convert';
import 'dart:math' as math;

import 'package:maplibre_flutter_gpu/maplibre_flutter_gpu.dart';

const _maximumSelectedTiles = 192;

final class const PlateauTileCatalog._(final List<_PlateauTile> _tiles) {
  factory fromJson(String source, Uri tilesetUri) {
    final root = switch (jsonDecode(source)) {
      {'root': final Map<Object?, Object?> root} => root,
      _ => throw const FormatException('Invalid PLATEAU tileset'),
    };

    final tiles = <_PlateauTile>[];
    void visit(Map<Object?, Object?> rawNode, String inheritedRefine) {
      final children = switch (rawNode['children']) {
        final List<Object?> value =>
          value.whereType<Map<Object?, Object?>>().toList(),
        _ => const <Map<Object?, Object?>>[],
      };
      final refine = switch (rawNode['refine']) {
        final String value => value.toUpperCase(),
        _ => inheritedRefine,
      };
      final content = rawNode['content'];
      final nodeBoundingVolume = rawNode['boundingVolume'];
      final contentBoundingVolume = content is Map
          ? content['boundingVolume']
          : null;
      final region = contentBoundingVolume is Map
          ? contentBoundingVolume['region']
          : nodeBoundingVolume is Map
          ? nodeBoundingVolume['region']
          : null;
      final relativeUri = content is Map
          ? content['uri'] ?? content['url']
          : null;
      final includesContent = refine == 'ADD' || children.isEmpty;
      if (includesContent &&
          relativeUri is String &&
          region is List &&
          region.length == 6) {
        final values = [
          for (final value in region)
            if (value is num) value.toDouble(),
        ];
        if (values.length == 6) {
          tiles.add(
            _PlateauTile(
              tilesetUri.resolve(relativeUri).toString(),
              _GeographicRegion(
                west: values[0] * 180 / math.pi,
                south: values[1] * 180 / math.pi,
                east: values[2] * 180 / math.pi,
                north: values[3] * 180 / math.pi,
              ),
            ),
          );
        }
      }
      for (final child in children) {
        visit(child, refine);
      }
    }

    visit(root, 'REPLACE');
    if (tiles.isEmpty) {
      throw const FormatException('PLATEAU tileset has no content');
    }
    return PlateauTileCatalog._(List.unmodifiable(tiles));
  }

  int get tileCount => _tiles.length;

  List<String> urlsForRegion(
    LatLngBounds bounds, {
    LatLng? priorityCenter,
    int maximumTiles = _maximumSelectedTiles,
  }) {
    if (maximumTiles <= 0) return const [];
    final region = _GeographicRegion(
      west: bounds.southwest.longitude,
      south: bounds.southwest.latitude,
      east: bounds.northeast.longitude,
      north: bounds.northeast.latitude,
    );
    final candidates = [
      for (final tile in _tiles)
        if (tile.region.intersects(region)) tile,
    ];
    final center = priorityCenter;
    if (center == null) {
      candidates.sort((a, b) => a.url.compareTo(b.url));
    } else {
      final longitudeScale = math.cos(center.latitude * math.pi / 180);
      double distance(_PlateauTile tile) {
        final latitude = tile.region.centerLatitude - center.latitude;
        final longitude =
            (tile.region.centerLongitude - center.longitude) * longitudeScale;
        return latitude * latitude + longitude * longitude;
      }

      candidates.sort((a, b) {
        final result = distance(a).compareTo(distance(b));
        return result != 0 ? result : a.url.compareTo(b.url);
      });
    }
    return candidates
        .take(maximumTiles)
        .map((tile) => tile.url)
        .toList(growable: false);
  }
}

final class const _PlateauTile(
  final String url,
  final _GeographicRegion region,
);

final class const _GeographicRegion({
  required final double west,
  required final double south,
  required final double east,
  required final double north,
}) {
  double get centerLatitude => (south + north) / 2;
  double get centerLongitude => (west + east) / 2;

  bool intersects(_GeographicRegion other) =>
      west <= other.east &&
      east >= other.west &&
      south <= other.north &&
      north >= other.south;
}
