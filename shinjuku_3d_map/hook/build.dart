import 'dart:convert';
import 'dart:io';

import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
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
      throw StateError('Unable to find Flutter SDK cache directory');
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
      throw StateError('Unable to find impellerc');
    }

    final shadersDirectory = packageRoot.resolve('shaders/');
    final manifestFile = shadersDirectory.resolve(
      'shinjuku_mesh.shaderbundle.json',
    );
    final manifest = switch (jsonDecode(
      await File.fromUri(manifestFile).readAsString(),
    )) {
      final Map<String, Object?> manifest => manifest,
      _ => throw const FormatException('Invalid shader manifest'),
    };
    output.dependencies.add(manifestFile);
    for (final entry in manifest.values) {
      if (entry
          case final Map<String, Object?> shader &&
              {'file': final String file}) {
        final source = shadersDirectory.resolve(file);
        output.dependencies.add(source);
        shader['file'] = source.toFilePath();
      }
    }

    final outputDirectory = Directory.fromUri(
      packageRoot.resolve('build/shaderbundles/'),
    );
    await outputDirectory.create(recursive: true);
    final outputFile = outputDirectory.uri.resolve(
      'shinjuku_mesh.shaderbundle',
    );
    final shaderLibraryDirectory = shaderCompiler.resolve('./shader_lib');
    final result = await Process.run(shaderCompiler.toFilePath(), [
      '--sl=${outputFile.toFilePath()}',
      '--shader-bundle=${jsonEncode(manifest)}',
      '--include=${shaderLibraryDirectory.toFilePath()}',
      '--gles-language-version=300',
    ], workingDirectory: packageRoot.toFilePath());
    if (result.exitCode != 0) {
      throw StateError(
        'Shader compilation failed:\n${result.stderr}\n${result.stdout}',
      );
    }
  });
}
