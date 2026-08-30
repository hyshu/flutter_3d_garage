import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:maplibre_flutter_gpu/maplibre_flutter_gpu.dart';

import 'plateau_b3dm_decoder.dart';
import 'plateau_tile_catalog.dart';

const plateauBuildingTilesetUrl =
    'https://assets.cms.plateau.reearth.io/assets/00/'
    'bed0bd-f882-4cde-b942-21d0f8d2ddc2/'
    '13104_shinjuku-ku_pref_2025_citygml_1_op_bldg_3dtiles_'
    '13104_shinjuku-ku_lod2/tileset.json';
const _shaderAsset = 'build/shaderbundles/shinjuku_mesh.shaderbundle';
const plateauTexturedAreaBounds = LatLngBounds(
  southwest: LatLng(35.685, 139.6848),
  northeast: LatLng(35.701, 139.7102),
);
const _maximumCachedTiles = 96;
const _maximumDecodedBytes = 768 * 1024 * 1024;
const _maximumConcurrentDownloads = 4;
const _textureWidth = 1024;
const _requestTimeout = Duration(seconds: 30);
const _retryDelays = [Duration(milliseconds: 250), Duration(seconds: 1)];

final class PlateauMeshRenderer extends ChangeNotifier {
  final _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  gpu.ShaderLibrary? _shaderLibrary;
  final _decodedTiles = <String, _DecodedTile>{};
  final _gpuTiles = <String, _GpuTile>{};
  final _failedUrls = <String>{};
  final _pendingUrls = <String>{};
  final _downloadQueue = <String>[];
  var _selectedUrls = const <String>{};
  PlateauTileCatalog? _catalog;
  LatLng? _lastCenter;
  Future<void>? _initialization;
  var _activeDownloads = 0;

  gpu.GpuContext? _resourceContext;
  gpu.RenderPipeline? _pipeline;
  gpu.HostBuffer? _uniforms;
  gpu.UniformSlot? _frameInfoSlot;
  gpu.UniformSlot? _textureSlot;
  var _isDisposed = false;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (_isDisposed) return;
    final results = await Future.wait<Object>([
      rootBundle.load(_shaderAsset),
      _downloadText(Uri.parse(plateauBuildingTilesetUrl)),
    ]);
    final library = await gpu.ShaderLibrary.fromBytes(results[0] as ByteData);
    if (library == null) {
      throw StateError('Unable to load Shinjuku mesh shaders');
    }
    if (_isDisposed) return;
    _shaderLibrary = library;
    _catalog = PlateauTileCatalog.fromJson(
      results[1] as String,
      Uri.parse(plateauBuildingTilesetUrl),
    );
    final center = _lastCenter;
    if (center != null) {
      updateCenter(center);
    }
    notifyListeners();
  }

  void updateCenter(LatLng center) {
    if (_isDisposed) return;
    _lastCenter = center;
    final urls =
        _catalog?.urlsForRegion(
          plateauTexturedAreaBounds,
          priorityCenter: center,
        ) ??
        const [];
    _selectedUrls = urls.toSet();
    final removedFromQueue = _downloadQueue
        .where((url) => !_selectedUrls.contains(url))
        .toList();
    _downloadQueue.removeWhere((url) => !_selectedUrls.contains(url));
    _pendingUrls.removeAll(removedFromQueue);
    for (final url in urls) {
      if (_decodedTiles.containsKey(url) ||
          _pendingUrls.contains(url) ||
          _failedUrls.contains(url)) {
        continue;
      }
      _pendingUrls.add(url);
      _downloadQueue.add(url);
    }
    final priority = {
      for (var index = 0; index < urls.length; index++) urls[index]: index,
    };
    _downloadQueue.sort((a, b) => priority[a]!.compareTo(priority[b]!));
    _trimCache();
    _startDownloads();
    notifyListeners();
  }

  void _startDownloads() {
    while (_activeDownloads < _maximumConcurrentDownloads &&
        _downloadQueue.isNotEmpty) {
      final url = _downloadQueue.removeAt(0);
      if (!_selectedUrls.contains(url)) {
        _pendingUrls.remove(url);
        continue;
      }
      _activeDownloads++;
      unawaited(_loadTile(url));
    }
  }

  Future<void> _loadTile(String url) async {
    try {
      final mesh = await _downloadTile(url);
      final decodedTextures = <(Uint8List, int, int)>[];
      for (final image in mesh.encodedImages) {
        decodedTextures.add(await _decodeTexture(image));
      }
      if (!_isDisposed && _selectedUrls.contains(url)) {
        _decodedTiles[url] = _DecodedTile(mesh, decodedTextures);
        _trimCache();
        notifyListeners();
      }
    } catch (error) {
      if (!_isDisposed) {
        _failedUrls.add(url);
        debugPrint('Unable to load PLATEAU 3D tile $url: $error');
      }
    } finally {
      _pendingUrls.remove(url);
      _activeDownloads--;
      if (!_isDisposed) _startDownloads();
    }
  }

  Future<B3dmMesh> _downloadTile(String url) async {
    final bytes = await _downloadBytes(Uri.parse(url));
    return compute(decodePlateauB3dm, bytes, debugLabel: 'PLATEAU B3DM');
  }

  Future<String> _downloadText(Uri uri) async =>
      utf8.decode(await _downloadBytes(uri));

  Future<Uint8List> _downloadBytes(Uri uri) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _downloadBytesOnce(uri);
      } catch (error) {
        if (_isDisposed ||
            attempt >= _retryDelays.length ||
            !_isRetryableDownloadError(error)) {
          rethrow;
        }
        debugPrint(
          'Retrying PLATEAU download $uri '
          '(${attempt + 2}/${_retryDelays.length + 1}): $error',
        );
        await Future<void>.delayed(_retryDelays[attempt]);
      }
    }
  }

  Future<Uint8List> _downloadBytesOnce(Uri uri) async {
    final request = await _httpClient.getUrl(uri);
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.timeout(_requestTimeout).drain<void>();
      throw _HttpResponseException(response.statusCode, uri);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_requestTimeout)) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<(Uint8List, int, int)> _decodeTexture(Uint8List encodedImage) async {
    final codec = await ui.instantiateImageCodec(
      encodedImage,
      targetWidth: _textureWidth,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final pixels = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (pixels == null) throw StateError('Unable to decode texture');
        return (
          Uint8List.fromList(pixels.buffer.asUint8List()),
          frame.image.width,
          frame.image.height,
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  void render(MapLibreGpuRenderContext context) {
    final transform = context.mapTransform;
    if (transform == null || _shaderLibrary == null) return;

    _ensureSharedResources(context.gpuContext);
    final pipeline = _pipeline;
    final uniforms = _uniforms;
    final frameInfoSlot = _frameInfoSlot;
    final textureSlot = _textureSlot;
    if (pipeline == null ||
        uniforms == null ||
        frameInfoSlot == null ||
        textureSlot == null) {
      return;
    }

    final pass = context.renderPass;
    pass.clearBindings();
    pass.bindPipeline(pipeline);
    pass.setColorBlendEnable(false);
    pass.setViewport(
      gpu.Viewport(
        width: context.physicalSize.width.round(),
        height: context.physicalSize.height.round(),
      ),
    );
    pass.setPrimitiveType(gpu.PrimitiveType.triangle);
    pass.setCullMode(gpu.CullMode.none);
    if (context.hasDepthStencilAttachment) {
      pass.setDepthWriteEnable(true);
      pass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    } else {
      pass.setDepthCompareOperation(gpu.CompareFunction.always);
    }

    uniforms.reset();
    for (final url in _selectedUrls) {
      final decoded = _decodedTiles[url];
      if (decoded == null) continue;
      final gpuTile = _gpuTiles.putIfAbsent(
        url,
        () => _uploadTile(context.gpuContext, decoded),
      );
      final mesh = decoded.mesh;
      final anchor = transform.project(
        LatLng(mesh.anchorLatitude, mesh.anchorLongitude),
      );
      final frameInfo = Float32List(20)
        ..setRange(0, 16, transform.viewProjectionMatrix)
        ..[16] = anchor.x
        ..[17] = anchor.y
        ..[18] = 0
        ..[19] = anchor.pixelsPerMeter;
      final uniformView = uniforms.emplace(frameInfo.buffer.asByteData());
      pass.bindUniform(frameInfoSlot, uniformView);

      for (final primitive in gpuTile.primitives) {
        final texture = gpuTile.textures[primitive.textureIndex];
        pass.bindVertexBuffer(primitive.vertexView);
        pass.bindIndexBuffer(primitive.indexView, gpu.IndexType.int32);
        pass.bindTexture(
          textureSlot,
          texture,
          sampler: gpu.SamplerOptions(
            minFilter: gpu.MinMagFilter.linear,
            magFilter: gpu.MinMagFilter.linear,
            widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
            heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
          ),
        );
        pass.drawIndexed(primitive.indexCount);
      }
    }
  }

  void _ensureSharedResources(gpu.GpuContext context) {
    if (identical(context, _resourceContext) && _pipeline != null) return;

    final library = _shaderLibrary!;
    final vertexShader = library['ShinjukuMeshVertex'];
    final fragmentShader = library['ShinjukuMeshFragment'];
    if (vertexShader == null || fragmentShader == null) {
      throw StateError('Shinjuku mesh shader entry points are missing');
    }

    _resourceContext = context;
    _gpuTiles.clear();
    _pipeline = context.createRenderPipeline(
      vertexShader,
      fragmentShader,
      vertexLayout: const gpu.VertexLayout(
        buffers: [
          gpu.VertexBuffer(
            strideInBytes: 5 * Float32List.bytesPerElement,
            attributes: [
              gpu.VertexAttribute(
                name: 'position',
                format: gpu.VertexFormat.float32x3,
              ),
              gpu.VertexAttribute(
                name: 'tex_coord',
                format: gpu.VertexFormat.float32x2,
                offsetInBytes: 3 * Float32List.bytesPerElement,
              ),
            ],
          ),
        ],
      ),
    );
    _frameInfoSlot = vertexShader.getUniformSlot('FrameInfo');
    _textureSlot = fragmentShader.getUniformSlot('u_texture');
    // Keep every tile's aligned uniform slice in one block. A small block rolls
    // over repeatedly on Metal, where uniform offsets are aligned to 256 bytes.
    _uniforms = context.createHostBuffer();
  }

  _GpuTile _uploadTile(gpu.GpuContext context, _DecodedTile decoded) =>
      _GpuTile(
        [
          for (final texture in decoded.textures)
            _uploadTexture(context, texture.$1, texture.$2, texture.$3),
        ],
        [
          for (final primitive in decoded.mesh.primitives)
            _uploadPrimitive(context, primitive),
        ],
      );

  gpu.Texture _uploadTexture(
    gpu.GpuContext context,
    Uint8List rgba,
    int width,
    int height,
  ) {
    final texture = context.createTexture(
      gpu.StorageMode.hostVisible,
      width,
      height,
      format: gpu.PixelFormat.r8g8b8a8UNormInt,
      enableRenderTargetUsage: false,
      enableShaderReadUsage: true,
    );
    texture.overwrite(ByteData.sublistView(rgba));
    return texture;
  }

  _GpuPrimitive _uploadPrimitive(
    gpu.GpuContext context,
    B3dmPrimitive primitive,
  ) {
    final vertexBuffer = context.createDeviceBufferWithCopy(
      primitive.vertices.buffer.asByteData(),
    );
    final indexBuffer = context.createDeviceBufferWithCopy(
      primitive.indices.buffer.asByteData(),
    );
    return _GpuPrimitive(
      gpu.BufferView(
        vertexBuffer,
        offsetInBytes: 0,
        lengthInBytes: primitive.vertices.lengthInBytes,
      ),
      gpu.BufferView(
        indexBuffer,
        offsetInBytes: 0,
        lengthInBytes: primitive.indices.lengthInBytes,
      ),
      primitive.indices.length,
      primitive.textureIndex,
    );
  }

  void _trimCache() {
    var decodedBytes = _decodedTiles.values.fold<int>(
      0,
      (total, tile) => total + tile.byteLength,
    );
    final removable = _decodedTiles.keys
        .where((url) => !_selectedUrls.contains(url))
        .toList();
    for (final url in removable) {
      if (_decodedTiles.length <= _maximumCachedTiles &&
          decodedBytes <= _maximumDecodedBytes) {
        break;
      }
      final removed = _decodedTiles.remove(url);
      if (removed != null) decodedBytes -= removed.byteLength;
      _gpuTiles.remove(url);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _downloadQueue.clear();
    _httpClient.close(force: true);
    super.dispose();
  }
}

bool _isRetryableDownloadError(Object error) {
  if (error is SocketException || error is TimeoutException) return true;
  if (error is! _HttpResponseException) return false;
  return error.statusCode == HttpStatus.requestTimeout ||
      error.statusCode == HttpStatus.tooManyRequests ||
      error.statusCode >= HttpStatus.internalServerError;
}

final class const _HttpResponseException(final int statusCode, final Uri uri)
    implements Exception {
  @override
  String toString() => 'HTTP $statusCode: $uri';
}

final class const _DecodedTile(
  final B3dmMesh mesh,
  final List<(Uint8List, int, int)> textures,
) {
  int get byteLength =>
      textures.fold<int>(0, (total, texture) => total + texture.$1.length) +
      mesh.primitives.fold<int>(
        0,
        (total, primitive) =>
            total +
            primitive.vertices.lengthInBytes +
            primitive.indices.lengthInBytes,
      );
}

final class const _GpuTile(
  final List<gpu.Texture> textures,
  final List<_GpuPrimitive> primitives,
);

final class const _GpuPrimitive(
  final gpu.BufferView vertexView,
  final gpu.BufferView indexView,
  final int indexCount,
  final int textureIndex,
);
