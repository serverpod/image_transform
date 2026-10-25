// Packages fetched libraries as release assets and writes native/manifest.json.
//
//   dart run tool/make_manifest.dart --release native-v0.1.0 \
//       --input artifacts --output release-assets --repo serverpod/image_transform
//
// <input>/<target>/ holds `libvips.{dylib,so,dll}` and `build-info.json` (as
// produced by tool/fetch_sharp_libvips.dart). Each library is gzipped into
// <output>/<target>-<file>.gz, and the manifest records the SHA-256 and size
// of the uncompressed file.

import 'dart:convert';
import 'dart:io';

import 'package:image_transform/src/native/library_fetcher.dart';
import 'package:image_transform/src/native/native_manifest.dart';
import 'package:image_transform/src/native/native_targets.dart';

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    options[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  final release = options['release'] ?? (throw ArgumentError('--release'));
  final input = Directory(options['input'] ?? 'artifacts');
  final output = Directory(options['output'] ?? 'release-assets');
  final repo = options['repo'] ?? 'serverpod/image_transform';
  await output.create(recursive: true);

  final pins =
      jsonDecode(File('native/sharp_libvips.json').readAsStringSync())
          as Map<String, Object?>;
  final targets = <String, ManifestEntry>{};
  for (final target in NativeTarget.all) {
    final dir = Directory('${input.path}/${target.name}');
    final library = File('${dir.path}/${target.libraryFileName}');
    if (!library.existsSync()) {
      stderr.writeln('warning: no library for ${target.name}');
      continue;
    }
    final asset = '${target.name}-${target.libraryFileName}.gz';
    final bytes = await library.readAsBytes();
    await File(
      '${output.path}/$asset',
    ).writeAsBytes(gzip.encode(bytes), flush: true);
    final info = File('${dir.path}/build-info.json');
    if (info.existsSync()) {
      await info.copy('${output.path}/${target.name}-build-info.json');
    }
    targets[target.name] = ManifestEntry(
      file: target.libraryFileName,
      asset: asset,
      sha256: await sha256OfFile(library),
      size: bytes.length,
    );
    stdout.writeln('${target.name}: ${target.libraryFileName} -> $asset');
  }

  final manifest = NativeManifest(
    release: release,
    baseUrl: 'https://github.com/$repo/releases/download/$release/',
    vipsVersion: pins['vipsVersion'] as String?,
    targets: targets,
  );
  final json =
      '${const JsonEncoder.withIndent('  ').convert(manifest.toJson())}\n';
  await File('native/manifest.json').writeAsString(json);
  await File('${output.path}/manifest.json').writeAsString(json);
  stdout.writeln('Wrote native/manifest.json for ${targets.length} targets');
}
