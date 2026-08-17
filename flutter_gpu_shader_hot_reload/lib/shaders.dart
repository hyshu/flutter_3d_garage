import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;

const _cubeShaderAsset =
    'build/shaderbundles/flutter_gpu_shader_hot_reload.shaderbundle';
const _shaderDirectoryOverride = String.fromEnvironment('CUBE_SHADER_DIR');
const _flutterRootOverride = String.fromEnvironment('FLUTTER_ROOT');

final class CubeShaderController {
  CubeShaderController._(this.library);

  final gpu.ShaderLibrary library;

  StreamSubscription<FileSystemEvent>? _watchSubscription;
  Timer? _debounceTimer;
  Directory? _sourceDirectory;
  File? _compiler;
  bool _compiling = false;
  bool _compileAgain = false;
  VoidCallback? _onReload;

  static Future<CubeShaderController> load() async {
    final bundledBytes = await rootBundle.load(_cubeShaderAsset);
    final library = await gpu.ShaderLibrary.fromBytes(bundledBytes);
    if (library == null) {
      throw StateError('Failed to load $_cubeShaderAsset from bytes.');
    }
    return CubeShaderController._(library);
  }

  void startWatching({required VoidCallback onReload}) {
    if (!kDebugMode || _watchSubscription != null) {
      return;
    }

    final sourceDirectory = _findShaderDirectory();
    if (sourceDirectory == null) {
      debugPrint(
        'Shader hot reload disabled: shaders directory was not found. '
        'Set --dart-define=CUBE_SHADER_DIR=/absolute/path/to/shaders.',
      );
      return;
    }
    final compiler = _findShaderCompiler(sourceDirectory.parent);
    if (compiler == null) {
      debugPrint(
        'Shader hot reload disabled: impellerc was not found. '
        'Set --dart-define=FLUTTER_ROOT=/absolute/path/to/flutter.',
      );
      return;
    }

    _sourceDirectory = sourceDirectory;
    _compiler = compiler;
    _onReload = onReload;
    _watchSubscription = sourceDirectory.watch().listen(
      _handleFileEvent,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Shader watcher error: $error');
      },
    );
    debugPrint('Shader hot reload watching ${sourceDirectory.path}');
  }

  void _handleFileEvent(FileSystemEvent event) {
    final path = event.path;
    if (!path.endsWith('.vert') &&
        !path.endsWith('.frag') &&
        !path.endsWith('.shaderbundle.json')) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      const Duration(milliseconds: 150),
      _compileAndReload,
    );
  }

  Future<void> _compileAndReload() async {
    if (_compiling) {
      _compileAgain = true;
      return;
    }

    _compiling = true;
    try {
      do {
        _compileAgain = false;
        await _compileOnce();
      } while (_compileAgain);
    } catch (error, stackTrace) {
      debugPrint('Shader hot reload failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _compiling = false;
    }
  }

  Future<void> _compileOnce() async {
    final sourceDirectory = _sourceDirectory!;
    final compiler = _compiler!;
    final manifestFile = File.fromUri(
      sourceDirectory.uri.resolve(
        'flutter_gpu_shader_hot_reload.shaderbundle.json',
      ),
    );
    final manifest =
        json.decode(await manifestFile.readAsString()) as Map<String, dynamic>;

    for (final entry in manifest.values) {
      if (entry is Map<String, dynamic> && entry['file'] is String) {
        entry['file'] = sourceDirectory.uri
            .resolve(entry['file'] as String)
            .toFilePath();
      }
    }

    final outputDirectory = Directory.fromUri(
      sourceDirectory.parent.uri.resolve('build/shader_hot_reload/'),
    );
    await outputDirectory.create(recursive: true);
    final outputFile = File.fromUri(
      outputDirectory.uri.resolve('flutter_gpu_shader_hot_reload.shaderbundle'),
    );
    final shaderLibraryDirectory = compiler.uri.resolve('./shader_lib');
    final result = await Process.run(compiler.path, [
      '--sl=${outputFile.path}',
      '--shader-bundle=${json.encode(manifest)}',
      '--include=${shaderLibraryDirectory.toFilePath()}',
    ], workingDirectory: sourceDirectory.parent.path);

    if (result.exitCode != 0) {
      throw StateError('${result.stderr}\n${result.stdout}'.trim());
    }

    final bytes = await outputFile.readAsBytes();
    final error = library.reinitializeFromBytes(ByteData.sublistView(bytes));
    if (error != null) {
      throw StateError(error);
    }
    _onReload?.call();
    debugPrint('Shader hot reload complete.');
  }

  Directory? _findShaderDirectory() {
    final candidates = <Directory>[
      if (_shaderDirectoryOverride.isNotEmpty)
        Directory(_shaderDirectoryOverride),
      Directory.fromUri(Directory.current.uri.resolve('shaders/')),
    ];

    var ancestor = File(Platform.resolvedExecutable).parent;
    for (var index = 0; index < 12; index++) {
      candidates.add(Directory.fromUri(ancestor.uri.resolve('shaders/')));
      final parent = ancestor.parent;
      if (parent.path == ancestor.path) {
        break;
      }
      ancestor = parent;
    }

    for (final candidate in candidates) {
      final manifest = File.fromUri(
        candidate.uri.resolve(
          'flutter_gpu_shader_hot_reload.shaderbundle.json',
        ),
      );
      if (manifest.existsSync()) {
        return candidate.absolute;
      }
    }
    return null;
  }

  File? _findShaderCompiler(Directory projectDirectory) {
    final flutterRoots = <String>[
      if (_flutterRootOverride.isNotEmpty) _flutterRootOverride,
      ?Platform.environment['FLUTTER_ROOT'],
    ];

    final generatedConfig = File.fromUri(
      projectDirectory.uri.resolve(
        'macos/Flutter/ephemeral/Flutter-Generated.xcconfig',
      ),
    );
    if (generatedConfig.existsSync()) {
      for (final line in generatedConfig.readAsLinesSync()) {
        if (line.startsWith('FLUTTER_ROOT=')) {
          flutterRoots.add(line.substring('FLUTTER_ROOT='.length));
          break;
        }
      }
    }

    for (final root in flutterRoots) {
      final engineArtifacts = Directory(root).uri
          .resolve('bin/cache/artifacts/engine/');
      for (final location in const [
        'darwin-arm64/impellerc',
        'darwin-x64/impellerc',
      ]) {
        final candidate = File.fromUri(engineArtifacts.resolve(location));
        if (candidate.existsSync()) {
          return candidate;
        }
      }
    }
    return null;
  }

  Future<void> dispose() async {
    _debounceTimer?.cancel();
    await _watchSubscription?.cancel();
  }
}
