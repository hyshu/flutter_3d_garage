// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/src/importer/src/gltf/draco/attributes.dart';
import 'package:flutter_scene/src/importer/src/gltf/draco/constants.dart';
import 'package:flutter_scene/src/importer/src/gltf/draco/mesh_decoder.dart';

final class const B3dmPrimitive({
  required final Float32List vertices,
  required final Uint32List indices,
  required final int textureIndex,
});

final class const B3dmMesh({
  required final double anchorLatitude,
  required final double anchorLongitude,
  required final List<B3dmPrimitive> primitives,
  required final List<Uint8List> encodedImages,
});

final class const _PrimitiveWithBatchIds({
  required final B3dmPrimitive primitive,
  required final Int32List batchIds,
});

B3dmMesh decodePlateauB3dm(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  _expectAscii(bytes, 0, 'b3dm');
  _expectUint32(data, 4, 1, 'B3DM version');

  final declaredLength = data.getUint32(8, Endian.little);
  if (declaredLength > bytes.length || declaredLength < 28) {
    throw const FormatException('Invalid B3DM byte length');
  }

  final featureJsonLength = data.getUint32(12, Endian.little);
  final featureBinaryLength = data.getUint32(16, Endian.little);
  final batchJsonLength = data.getUint32(20, Endian.little);
  final batchBinaryLength = data.getUint32(24, Endian.little);
  final featureTable = _decodeJsonMap(
    bytes,
    28,
    featureJsonLength,
    'B3DM feature table',
  );
  final batchLength = _integer(featureTable['BATCH_LENGTH'], 'BATCH_LENGTH');

  final glbOffset =
      28 +
      featureJsonLength +
      featureBinaryLength +
      batchJsonLength +
      batchBinaryLength;
  _expectAscii(bytes, glbOffset, 'glTF');
  _expectUint32(data, glbOffset + 4, 2, 'GLB version');
  final glbLength = data.getUint32(glbOffset + 8, Endian.little);
  if (glbOffset + glbLength > declaredLength) {
    throw const FormatException('GLB exceeds B3DM bounds');
  }

  final jsonLength = data.getUint32(glbOffset + 12, Endian.little);
  _expectUint32(data, glbOffset + 16, 0x4e4f534a, 'GLB JSON chunk');
  final jsonOffset = glbOffset + 20;
  final gltf = _decodeJsonMap(bytes, jsonOffset, jsonLength, 'GLB JSON');
  final extensions = gltf['extensions'];
  final cesiumRtc = extensions is Map ? extensions['CESIUM_RTC'] : null;
  final rtcCenterValue =
      featureTable['RTC_CENTER'] ??
      (cesiumRtc is Map ? cesiumRtc['center'] : null);
  final rtcCenter = _numberList(rtcCenterValue, 'RTC_CENTER', 3);

  final binaryHeader = jsonOffset + jsonLength;
  final binaryLength = data.getUint32(binaryHeader, Endian.little);
  _expectUint32(data, binaryHeader + 4, 0x004e4942, 'GLB BIN chunk');
  final binaryOffset = binaryHeader + 8;
  final binaryEnd = binaryOffset + binaryLength;
  if (binaryEnd > glbOffset + glbLength) {
    throw const FormatException('GLB BIN chunk exceeds bounds');
  }

  final accessors = _mapList(gltf['accessors'], 'accessors');
  final bufferViews = _mapList(gltf['bufferViews'], 'bufferViews');
  final meshes = _mapList(gltf['meshes'], 'meshes');
  final materials = _optionalMapList(gltf['materials'], 'materials');
  final textures = _optionalMapList(gltf['textures'], 'textures');
  final images = _optionalMapList(gltf['images'], 'images');
  final meshTransforms = _meshTransforms(gltf, meshes.length);

  final encodedImages = <Uint8List>[];
  for (final image in images) {
    if (image['mimeType'] != 'image/jpeg' &&
        image['mimeType'] != 'image/png' &&
        image['mimeType'] != 'image/webp') {
      throw const FormatException('Unsupported GLB image');
    }
    final viewIndex = _integer(image['bufferView'], 'image buffer view');
    final view = _at(bufferViews, viewIndex, 'image buffer view');
    final offset = binaryOffset + _optionalInteger(view['byteOffset'], 0);
    final length = _integer(view['byteLength'], 'image byte length');
    _expectRange(offset, length, binaryOffset, binaryEnd, 'image');
    encodedImages.add(
      Uint8List.fromList(bytes.sublist(offset, offset + length)),
    );
  }

  final geodetic = _ecefToGeodetic(rtcCenter[0], rtcCenter[1], rtcCenter[2]);
  final latitude = geodetic.$1;
  final longitude = geodetic.$2;
  final sinLatitude = math.sin(latitude);
  final cosLatitude = math.cos(latitude);
  final sinLongitude = math.sin(longitude);
  final cosLongitude = math.cos(longitude);

  const floatsPerVertex = 5;
  final decodedPrimitives = <_PrimitiveWithBatchIds>[];
  final minimumUpByBatch = <int, double>{};
  for (var meshIndex = 0; meshIndex < meshes.length; meshIndex++) {
    final mesh = meshes[meshIndex];
    final rawPrimitives = mesh['primitives'];
    if (rawPrimitives is! List) {
      throw const FormatException('GLB mesh has no primitives');
    }
    final nodeTransform = meshTransforms[meshIndex];
    if (nodeTransform == null) {
      throw FormatException('GLB mesh $meshIndex has no scene node');
    }

    for (final rawPrimitive in rawPrimitives) {
      final primitive = _map(rawPrimitive, 'primitive');
      if (_optionalInteger(primitive['mode'], 4) != 4) {
        throw const FormatException('GLB primitive is not triangles');
      }
      final attributes = _map(primitive['attributes'], 'mesh attributes');
      final textureIndex = _textureIndex(
        primitive,
        materials,
        textures,
        images.length,
      );
      if (textureIndex == null || attributes['TEXCOORD_0'] == null) continue;
      final positionAccessor = _at(
        accessors,
        _integer(attributes['POSITION'], 'POSITION accessor'),
        'POSITION accessor',
      );
      _expectAccessor(positionAccessor, componentType: 5126, type: 'VEC3');
      final vertexCount = _integer(positionAccessor['count'], 'position count');

      Map<String, dynamic>? uvAccessor;
      if (attributes['TEXCOORD_0'] != null) {
        uvAccessor = _at(
          accessors,
          _integer(attributes['TEXCOORD_0'], 'UV accessor'),
          'UV accessor',
        );
        _expectAccessor(uvAccessor, componentType: 5126, type: 'VEC2');
        if (_integer(uvAccessor['count'], 'UV count') != vertexCount) {
          throw const FormatException('Position and UV counts differ');
        }
      }

      Map<String, dynamic>? batchIdAccessor;
      if (attributes['_BATCHID'] != null) {
        batchIdAccessor = _at(
          accessors,
          _integer(attributes['_BATCHID'], '_BATCHID accessor'),
          '_BATCHID accessor',
        );
        _expectBatchIdAccessor(batchIdAccessor);
        if (_integer(batchIdAccessor['count'], '_BATCHID count') !=
            vertexCount) {
          throw const FormatException('Position and _BATCHID counts differ');
        }
      }

      final primitiveExtensions = primitive['extensions'];
      final dracoValue = primitiveExtensions is Map
          ? primitiveExtensions['KHR_draco_mesh_compression']
          : null;
      final draco = dracoValue == null
          ? null
          : _map(dracoValue, 'Draco extension');

      late final double Function(int element, int component) readPosition;
      double Function(int element, int component)? readUv;
      int Function(int element)? readBatchId;
      late final Uint32List indices;

      if (draco != null) {
        final dracoAttributes = _map(draco['attributes'], 'Draco attributes');
        final view = _at(
          bufferViews,
          _integer(draco['bufferView'], 'Draco buffer view'),
          'Draco buffer view',
        );
        final offset = binaryOffset + _optionalInteger(view['byteOffset'], 0);
        final length = _integer(view['byteLength'], 'Draco byte length');
        _expectRange(offset, length, binaryOffset, binaryEnd, 'Draco payload');
        final decoded = decodeDracoMesh(
          Uint8List.sublistView(bytes, offset, offset + length),
        );
        if (decoded.numPoints != vertexCount) {
          throw const FormatException(
            'Position accessor and Draco point counts differ',
          );
        }

        final positionAttribute = _dracoAttribute(
          decoded,
          dracoAttributes,
          'POSITION',
          3,
        );
        final positionData = ByteData.sublistView(
          positionAttribute.pointBytes(vertexCount),
        );
        readPosition = (element, component) => _readDracoNumber(
          positionData,
          positionAttribute,
          element,
          component,
        );

        if (uvAccessor != null) {
          final uvAttribute = _dracoAttribute(
            decoded,
            dracoAttributes,
            'TEXCOORD_0',
            2,
          );
          final uvData = ByteData.sublistView(
            uvAttribute.pointBytes(vertexCount),
          );
          readUv = (element, component) =>
              _readDracoNumber(uvData, uvAttribute, element, component);
        }

        if (batchIdAccessor != null) {
          final batchIdAttribute = _dracoAttribute(
            decoded,
            dracoAttributes,
            '_BATCHID',
            1,
          );
          final batchIdData = ByteData.sublistView(
            batchIdAttribute.pointBytes(vertexCount),
          );
          readBatchId = (element) => _readDracoBatchId(
            batchIdData,
            batchIdAttribute,
            element,
            batchLength,
          );
        }

        final indexAccessor = _indexAccessor(primitive, accessors);
        final indexCount = _integer(indexAccessor['count'], 'index count');
        if (decoded.faces.length != indexCount) {
          throw const FormatException(
            'Index accessor and Draco face counts differ',
          );
        }
        indices = Uint32List(indexCount);
        for (var index = 0; index < indexCount; index++) {
          final value = decoded.faces[index];
          if (value < 0 || value >= vertexCount) {
            throw const FormatException('Draco index is out of range');
          }
          indices[index] = value;
        }
      } else {
        readPosition = (element, component) => _readFloat(
          data,
          binaryOffset,
          binaryEnd,
          bufferViews,
          positionAccessor,
          element,
          component,
          3,
        );
        if (uvAccessor != null) {
          final accessor = uvAccessor;
          readUv = (element, component) => _readFloat(
            data,
            binaryOffset,
            binaryEnd,
            bufferViews,
            accessor,
            element,
            component,
            2,
          );
        }
        if (batchIdAccessor != null) {
          final accessor = batchIdAccessor;
          readBatchId = (element) => _readBatchId(
            data,
            binaryOffset,
            binaryEnd,
            bufferViews,
            accessor,
            element,
            batchLength,
          );
        }

        final indexAccessor = _indexAccessor(primitive, accessors);
        final indexCount = _integer(indexAccessor['count'], 'index count');
        indices = Uint32List(indexCount);
        for (var index = 0; index < indexCount; index++) {
          final value = _readIndex(
            data,
            binaryOffset,
            binaryEnd,
            bufferViews,
            indexAccessor,
            index,
          );
          if (value >= vertexCount) {
            throw const FormatException('Index is out of range');
          }
          indices[index] = value;
        }
      }

      final vertices = Float32List(vertexCount * floatsPerVertex);
      final batchIds = Int32List(vertexCount);
      for (var index = 0; index < vertexCount; index++) {
        final x = readPosition(index, 0);
        final y = readPosition(index, 1);
        final z = readPosition(index, 2);
        final transformed = _transform(nodeTransform, x, y, z);

        // glTF is Y-up while 3D Tiles is Z-up.
        final ecefX = transformed.$1;
        final ecefY = -transformed.$3;
        final ecefZ = transformed.$2;
        final east = -sinLongitude * ecefX + cosLongitude * ecefY;
        final north =
            -sinLatitude * cosLongitude * ecefX -
            sinLatitude * sinLongitude * ecefY +
            cosLatitude * ecefZ;
        final up =
            cosLatitude * cosLongitude * ecefX +
            cosLatitude * sinLongitude * ecefY +
            sinLatitude * ecefZ;
        final batchIdReader = readBatchId;
        final batchId = batchIdReader == null ? -1 : batchIdReader(index);
        batchIds[index] = batchId;
        minimumUpByBatch[batchId] = math.min(
          minimumUpByBatch[batchId] ?? double.infinity,
          up,
        );

        final output = index * floatsPerVertex;
        vertices[output] = east;
        vertices[output + 1] = north;
        vertices[output + 2] = up;
        final uvReader = readUv!;
        vertices[output + 3] = uvReader(index, 0);
        vertices[output + 4] = uvReader(index, 1);
      }

      decodedPrimitives.add(
        _PrimitiveWithBatchIds(
          primitive: B3dmPrimitive(
            vertices: vertices,
            indices: indices,
            textureIndex: textureIndex,
          ),
          batchIds: batchIds,
        ),
      );
    }
  }
  for (final decoded in decodedPrimitives) {
    final vertices = decoded.primitive.vertices;
    for (var index = 0; index < vertices.length; index += floatsPerVertex) {
      final batchId = decoded.batchIds[index ~/ floatsPerVertex];
      vertices[index + 2] -= minimumUpByBatch[batchId]! - 0.25;
    }
  }

  return B3dmMesh(
    anchorLatitude: latitude * 180 / math.pi,
    anchorLongitude: longitude * 180 / math.pi,
    primitives: [for (final decoded in decodedPrimitives) decoded.primitive],
    encodedImages: encodedImages,
  );
}

DracoAttribute _dracoAttribute(
  DracoDecodedMesh mesh,
  Map<String, dynamic> attributes,
  String semantic,
  int componentCount,
) {
  final uniqueId = _integer(attributes[semantic], '$semantic Draco attribute');
  final attribute = mesh.attributeByUniqueId(uniqueId);
  if (attribute == null) {
    throw FormatException('Draco stream is missing $semantic');
  }
  if (attribute.numComponents != componentCount) {
    throw FormatException('Invalid Draco $semantic component count');
  }
  if (attribute.dataType != DracoDataType.int8 &&
      attribute.dataType != DracoDataType.uint8 &&
      attribute.dataType != DracoDataType.int16 &&
      attribute.dataType != DracoDataType.uint16 &&
      attribute.dataType != DracoDataType.uint32 &&
      attribute.dataType != DracoDataType.float32) {
    throw FormatException('Unsupported Draco $semantic data type');
  }
  return attribute;
}

double _readDracoNumber(
  ByteData data,
  DracoAttribute attribute,
  int element,
  int component,
) {
  if (element < 0 || component < 0 || component >= attribute.numComponents) {
    throw const FormatException('Draco attribute index is out of range');
  }
  final offset =
      element * attribute.byteStride + component * attribute.componentBytes;
  _expectRange(
    offset,
    attribute.componentBytes,
    0,
    data.lengthInBytes,
    'Draco attribute',
  );
  return switch (attribute.dataType) {
    DracoDataType.int8 => data.getInt8(offset).toDouble(),
    DracoDataType.uint8 => data.getUint8(offset).toDouble(),
    DracoDataType.int16 => data.getInt16(offset, Endian.little).toDouble(),
    DracoDataType.uint16 => data.getUint16(offset, Endian.little).toDouble(),
    DracoDataType.uint32 => data.getUint32(offset, Endian.little).toDouble(),
    DracoDataType.float32 => data.getFloat32(offset, Endian.little),
    _ => throw const FormatException('Unsupported Draco attribute data type'),
  };
}

int _readDracoBatchId(
  ByteData data,
  DracoAttribute attribute,
  int element,
  int batchLength,
) {
  final value = _readDracoNumber(data, attribute, element, 0);
  final batchId = value.toInt();
  if (!value.isFinite ||
      value != batchId ||
      batchId < 0 ||
      batchId >= batchLength) {
    throw const FormatException('Invalid _BATCHID value');
  }
  return batchId;
}

Map<String, dynamic> _indexAccessor(
  Map<String, dynamic> primitive,
  List<Map<String, dynamic>> accessors,
) {
  final accessor = _at(
    accessors,
    _integer(primitive['indices'], 'index accessor'),
    'index accessor',
  );
  if (accessor['type'] != 'SCALAR' ||
      (accessor['componentType'] != 5121 &&
          accessor['componentType'] != 5123 &&
          accessor['componentType'] != 5125)) {
    throw const FormatException('Unsupported index accessor');
  }
  return accessor;
}

void _expectBatchIdAccessor(Map<String, dynamic> accessor) {
  final componentType = accessor['componentType'];
  if (accessor['type'] != 'SCALAR' ||
      (componentType != 5121 &&
          componentType != 5123 &&
          componentType != 5125 &&
          componentType != 5126)) {
    throw const FormatException('Unsupported _BATCHID accessor');
  }
}

int _readBatchId(
  ByteData data,
  int binaryOffset,
  int binaryEnd,
  List<Map<String, dynamic>> views,
  Map<String, dynamic> accessor,
  int element,
  int batchLength,
) {
  final view = _at(
    views,
    _integer(accessor['bufferView'], '_BATCHID buffer view'),
    '_BATCHID buffer view',
  );
  final componentType = _integer(
    accessor['componentType'],
    '_BATCHID component type',
  );
  final size = switch (componentType) {
    5121 => 1,
    5123 => 2,
    5125 || 5126 => 4,
    _ => throw const FormatException('Unsupported _BATCHID component type'),
  };
  final stride = _optionalInteger(view['byteStride'], size);
  final offset =
      binaryOffset +
      _optionalInteger(view['byteOffset'], 0) +
      _optionalInteger(accessor['byteOffset'], 0) +
      element * stride;
  _expectRange(offset, size, binaryOffset, binaryEnd, '_BATCHID accessor');
  final value = switch (componentType) {
    5121 => data.getUint8(offset),
    5123 => data.getUint16(offset, Endian.little),
    5125 => data.getUint32(offset, Endian.little),
    5126 => data.getFloat32(offset, Endian.little),
    _ => throw const FormatException('Unsupported _BATCHID component type'),
  };
  final batchId = value.toInt();
  if (value != batchId || batchId < 0 || batchId >= batchLength) {
    throw const FormatException('Invalid _BATCHID value');
  }
  return batchId;
}

int? _textureIndex(
  Map<String, dynamic> primitive,
  List<Map<String, dynamic>> materials,
  List<Map<String, dynamic>> textures,
  int imageCount,
) {
  if (primitive['material'] == null) return null;
  final material = _at(
    materials,
    _integer(primitive['material'], 'material'),
    'material',
  );
  final pbr = material['pbrMetallicRoughness'];
  if (pbr is! Map || pbr['baseColorTexture'] is! Map) return null;
  final textureInfo = Map<String, dynamic>.from(pbr['baseColorTexture'] as Map);
  final texture = _at(
    textures,
    _integer(textureInfo['index'], 'texture'),
    'texture',
  );
  final textureExtensions = texture['extensions'];
  final webp = textureExtensions is Map
      ? textureExtensions['EXT_texture_webp']
      : null;
  final source = _integer(
    texture['source'] ?? (webp is Map ? webp['source'] : null),
    'texture source',
  );
  if (source < 0 || source >= imageCount) {
    throw const FormatException('Texture source is out of range');
  }
  return source;
}

Map<int, List<double>> _meshTransforms(
  Map<String, dynamic> gltf,
  int meshCount,
) {
  final nodes = _mapList(gltf['nodes'], 'nodes');
  final scenes = _mapList(gltf['scenes'], 'scenes');
  final sceneIndex = _optionalInteger(gltf['scene'], 0);
  final scene = _at(scenes, sceneIndex, 'scene');
  final rootNodes = _integerList(scene['nodes'], 'scene nodes');
  final transforms = <int, List<double>>{};

  void visit(int nodeIndex, List<double> parent, Set<int> path) {
    if (!path.add(nodeIndex)) throw const FormatException('Node cycle');
    final node = _at(nodes, nodeIndex, 'node');
    final local = switch (node['matrix']) {
      final List values when values.length == 16 => [
        for (final value in values) _number(value, 'node matrix'),
      ],
      null => _identityMatrix,
      _ => throw const FormatException('Invalid node matrix'),
    };
    final world = _multiply(parent, local);
    if (node['mesh'] != null) {
      final meshIndex = _integer(node['mesh'], 'node mesh');
      if (meshIndex < 0 || meshIndex >= meshCount) {
        throw const FormatException('Node mesh is out of range');
      }
      transforms[meshIndex] = world;
    }
    for (final child in _optionalIntegerList(node['children'])) {
      visit(child, world, {...path});
    }
  }

  for (final root in rootNodes) {
    visit(root, _identityMatrix, <int>{});
  }
  return transforms;
}

List<double> _multiply(List<double> left, List<double> right) {
  final result = List<double>.filled(16, 0);
  for (var column = 0; column < 4; column++) {
    for (var row = 0; row < 4; row++) {
      for (var index = 0; index < 4; index++) {
        result[column * 4 + row] +=
            left[index * 4 + row] * right[column * 4 + index];
      }
    }
  }
  return result;
}

(double, double, double) _transform(
  List<double> matrix,
  double x,
  double y,
  double z,
) => (
  matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12],
  matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
  matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14],
);

double _readFloat(
  ByteData data,
  int binaryOffset,
  int binaryEnd,
  List<Map<String, dynamic>> views,
  Map<String, dynamic> accessor,
  int element,
  int component,
  int componentCount,
) {
  final view = _at(
    views,
    _integer(accessor['bufferView'], 'accessor buffer view'),
    'accessor buffer view',
  );
  final stride = _optionalInteger(
    view['byteStride'],
    componentCount * Float32List.bytesPerElement,
  );
  final offset =
      binaryOffset +
      _optionalInteger(view['byteOffset'], 0) +
      _optionalInteger(accessor['byteOffset'], 0) +
      element * stride +
      component * Float32List.bytesPerElement;
  _expectRange(offset, 4, binaryOffset, binaryEnd, 'float accessor');
  return data.getFloat32(offset, Endian.little);
}

int _readIndex(
  ByteData data,
  int binaryOffset,
  int binaryEnd,
  List<Map<String, dynamic>> views,
  Map<String, dynamic> accessor,
  int element,
) {
  final view = _at(
    views,
    _integer(accessor['bufferView'], 'index buffer view'),
    'index buffer view',
  );
  final componentType = accessor['componentType'];
  final size = switch (componentType) {
    5121 => 1,
    5123 => 2,
    5125 => 4,
    _ => throw const FormatException('Unsupported index component type'),
  };
  final stride = _optionalInteger(view['byteStride'], size);
  final offset =
      binaryOffset +
      _optionalInteger(view['byteOffset'], 0) +
      _optionalInteger(accessor['byteOffset'], 0) +
      element * stride;
  _expectRange(offset, size, binaryOffset, binaryEnd, 'index accessor');
  return switch (componentType) {
    5121 => data.getUint8(offset),
    5123 => data.getUint16(offset, Endian.little),
    5125 => data.getUint32(offset, Endian.little),
    _ => throw const FormatException('Unsupported index component type'),
  };
}

(double, double, double) _ecefToGeodetic(double x, double y, double z) {
  const semiMajorAxis = 6378137.0;
  const flattening = 1 / 298.257223563;
  const semiMinorAxis = semiMajorAxis * (1 - flattening);
  const eccentricitySquared = flattening * (2 - flattening);
  const secondEccentricitySquared =
      (semiMajorAxis * semiMajorAxis - semiMinorAxis * semiMinorAxis) /
      (semiMinorAxis * semiMinorAxis);
  final horizontal = math.sqrt(x * x + y * y);
  final theta = math.atan2(semiMajorAxis * z, semiMinorAxis * horizontal);
  final sinTheta = math.sin(theta);
  final cosTheta = math.cos(theta);
  final latitude = math.atan2(
    z + secondEccentricitySquared * semiMinorAxis * math.pow(sinTheta, 3),
    horizontal - eccentricitySquared * semiMajorAxis * math.pow(cosTheta, 3),
  );
  final longitude = math.atan2(y, x);
  final radius =
      semiMajorAxis /
      math.sqrt(1 - eccentricitySquared * math.pow(math.sin(latitude), 2));
  final height = horizontal / math.cos(latitude) - radius;
  return (latitude, longitude, height);
}

Map<String, dynamic> _decodeJsonMap(
  Uint8List bytes,
  int offset,
  int length,
  String name,
) {
  if (length == 0) throw FormatException('$name is empty');
  _expectRange(offset, length, 0, bytes.length, name);
  final source = utf8
      .decode(bytes.sublist(offset, offset + length))
      .replaceAll('\u0000', '')
      .trim();
  return _map(jsonDecode(source), name);
}

void _expectAccessor(
  Map<String, dynamic> accessor, {
  required int componentType,
  required String type,
}) {
  if (accessor['componentType'] != componentType || accessor['type'] != type) {
    throw FormatException('Unsupported $type accessor');
  }
}

Map<String, dynamic> _map(Object? value, String name) {
  if (value is! Map) throw FormatException('Invalid $name');
  return Map<String, dynamic>.from(value);
}

List<Map<String, dynamic>> _mapList(Object? value, String name) {
  if (value is! List) throw FormatException('Invalid $name');
  return [for (final item in value) _map(item, name)];
}

List<Map<String, dynamic>> _optionalMapList(Object? value, String name) =>
    value == null ? const [] : _mapList(value, name);

Map<String, dynamic> _at(
  List<Map<String, dynamic>> values,
  int index,
  String name,
) {
  if (index < 0 || index >= values.length) {
    throw FormatException('$name is out of range');
  }
  return values[index];
}

int _integer(Object? value, String name) {
  if (value is! num || value.toInt() != value) {
    throw FormatException('Invalid $name');
  }
  return value.toInt();
}

int _optionalInteger(Object? value, int fallback) =>
    value == null ? fallback : _integer(value, 'integer');

List<int> _integerList(Object? value, String name) {
  if (value is! List) throw FormatException('Invalid $name');
  return [for (final item in value) _integer(item, name)];
}

List<int> _optionalIntegerList(Object? value) =>
    value == null ? const [] : _integerList(value, 'integer list');

double _number(Object? value, String name) {
  if (value is! num) throw FormatException('Invalid $name');
  return value.toDouble();
}

List<double> _numberList(Object? value, String name, int length) {
  if (value is! List || value.length != length) {
    throw FormatException('Invalid $name');
  }
  return [for (final item in value) _number(item, name)];
}

void _expectRange(
  int offset,
  int length,
  int lowerBound,
  int upperBound,
  String name,
) {
  if (offset < lowerBound || length < 0 || offset + length > upperBound) {
    throw FormatException('$name exceeds bounds');
  }
}

void _expectAscii(Uint8List bytes, int offset, String expected) {
  if (offset < 0 || offset + expected.length > bytes.length) {
    throw FormatException('Missing $expected magic');
  }
  final actual = ascii.decode(bytes.sublist(offset, offset + expected.length));
  if (actual != expected) throw FormatException('Invalid $expected magic');
}

void _expectUint32(ByteData data, int offset, int expected, String name) {
  if (offset < 0 || offset + 4 > data.lengthInBytes) {
    throw FormatException('Missing $name');
  }
  if (data.getUint32(offset, Endian.little) != expected) {
    throw FormatException('Unsupported $name');
  }
}

const _identityMatrix = <double>[
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
];
