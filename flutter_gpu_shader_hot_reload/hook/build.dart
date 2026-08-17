import 'dart:convert';
import 'dart:io';

import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageRoot = input.packageRoot;
    final dartExecutable = Uri.file(Platform.resolvedExecutable);

    Uri? flutterCacheDirectory;
    for (
      var index = dartExecutable.pathSegments.length - 1;
      index >= 0;
      index--
    ) {
      final segment = dartExecutable.pathSegments[index];
      if (segment == 'dart-sdk' || segment == 'artifacts') {
        flutterCacheDirectory = dartExecutable.replace(
          pathSegments: dartExecutable.pathSegments.sublist(0, index) + [''],
        );
        break;
      }
    }
    if (flutterCacheDirectory == null) {
      throw StateError('Unable to find the Flutter SDK cache directory.');
    }

    final engineArtifacts = flutterCacheDirectory.resolve('artifacts/engine/');
    const compilerLocations = [
      'darwin-arm64/impellerc',
      'darwin-x64/impellerc',
      'linux-x64/impellerc',
      'windows-x64/impellerc.exe',
    ];

    Uri? shaderCompiler;
    for (final location in compilerLocations) {
      final candidate = engineArtifacts.resolve(location);
      if (await File.fromUri(candidate).exists()) {
        shaderCompiler = candidate;
        break;
      }
    }
    if (shaderCompiler == null) {
      throw StateError('Unable to find impellerc in the Flutter SDK cache.');
    }

    final shadersDirectory = packageRoot.resolve('shaders/');
    final manifestFile = shadersDirectory.resolve(
      'flutter_gpu_shader_hot_reload.shaderbundle.json',
    );
    final manifest = json.decode(
      await File.fromUri(manifestFile).readAsString(),
    ) as Map<String, dynamic>;

    for (final entry in manifest.values) {
      if (entry is Map<String, dynamic> && entry['file'] is String) {
        entry['file'] = shadersDirectory
            .resolve(entry['file'] as String)
            .toFilePath();
      }
    }

    final outputDirectory = Directory.fromUri(
      packageRoot.resolve('build/shaderbundles/'),
    );
    await outputDirectory.create(recursive: true);
    final outputFile = outputDirectory.uri.resolve(
      'flutter_gpu_shader_hot_reload.shaderbundle',
    );
    final shaderLibraryDirectory = shaderCompiler.resolve('./shader_lib');

    final result = await Process.run(shaderCompiler.toFilePath(), [
      '--sl=${outputFile.toFilePath()}',
      '--shader-bundle=${json.encode(manifest)}',
      '--include=${shaderLibraryDirectory.toFilePath()}',
    ], workingDirectory: packageRoot.toFilePath());

    if (result.exitCode != 0) {
      throw StateError(
        'Shader compilation failed:\n${result.stderr}\n${result.stdout}',
      );
    }
  });
}
