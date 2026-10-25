// Provides libvips as a code asset for the FFI backend (specs/04).
//
// Where the library comes from, in order of precedence:
//  1. `libvips: none`: no asset (the CLI backend is used).
//  2. `libvips: system`: a system-installed libvips (DynamicLoadingSystem).
//  3. `library_dir`: a directory with a prebuilt `libvips.{dylib,so,dll}`.
//  4. `native/out/<target>/` in this package (local builds made with
//     `dart run tool/fetch_sharp_libvips.dart`).
//  5. Download from the GitHub release in `native/manifest.json`, verified
//     against its SHA-256 (default).
//
// Configure in the application's pubspec.yaml:
//
//   hooks:
//     user_defines:
//       image_transform:
//         libvips: bundled            # bundled (default) | system | none
//         library_dir: path/to/dir    # offline / air-gapped builds
//         download_base_url: https:// # mirror of the release assets
//         allow_download: false       # never download
//         require_native: true        # fail the build instead of warning
//
// Without `require_native`, an unsupported target or a failed download only
// logs a warning: the package still builds, and the FFI backend reports
// itself unavailable at runtime (the CLI backend may still work).

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:image_transform/src/native/library_fetcher.dart';
import 'package:image_transform/src/native/native_manifest.dart';
import 'package:image_transform/src/native/native_targets.dart';

const _assetName = 'src/ffi/libvips.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    void log(String message) => stdout.writeln('image_transform: $message');

    final mode = input.userDefines['libvips'] ?? 'bundled';
    if (mode == 'none') return;

    final target = _target(input.config.code);
    if (target == null) {
      _unavailable(
        input,
        log,
        'no prebuilt libvips for ${input.config.code.targetOS}/'
        '${input.config.code.targetArchitecture}',
      );
      return;
    }

    if (mode == 'system') {
      final name = target.systemLibraryNames.firstWhere(
        (n) => !n.startsWith('/') || File(n).existsSync(),
        orElse: () => target.systemLibraryNames.last,
      );
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: _assetName,
          linkMode: DynamicLoadingSystem(Uri.file(name)),
        ),
      );
      return;
    }
    if (mode != 'bundled') {
      throw ArgumentError.value(mode, 'libvips', 'Use bundled, system or none');
    }

    final file = await _resolve(input, output, target, log);
    if (file == null) return;
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: file.absolute.uri,
      ),
    );
  });
}

NativeTarget? _target(CodeConfig code) {
  final os = switch (code.targetOS) {
    OS.macOS => NativeOS.macos,
    OS.linux => NativeOS.linux,
    OS.windows => NativeOS.windows,
    _ => null,
  };
  final arch = switch (code.targetArchitecture) {
    Architecture.x64 => NativeArch.x64,
    Architecture.arm64 => NativeArch.arm64,
    _ => null,
  };
  if (os == null || arch == null) return null;
  return NativeTarget(os, arch, musl: os == NativeOS.linux && hostUsesMusl());
}

void _unavailable(BuildInput input, void Function(String) log, String why) {
  if (input.userDefines['require_native'] == true) {
    throw LibraryFetchException('$why (require_native is set)');
  }
  log(
    'WARNING: $why. The FFI backend will be unavailable; image_transform '
    'falls back to the libvips CLI if installed. Set the user-define '
    'image_transform.library_dir to use your own build.',
  );
}

Future<File?> _resolve(
  BuildInput input,
  BuildOutputBuilder output,
  NativeTarget target,
  void Function(String) log,
) async {
  // 1. Explicit directory.
  final libraryDir = input.userDefines.path('library_dir');
  if (libraryDir != null) {
    final file = File.fromUri(libraryDir.resolve(target.libraryFileName));
    if (!file.existsSync()) {
      throw LibraryFetchException(
        'library_dir ${libraryDir.toFilePath()} has no ${target.libraryFileName}',
      );
    }
    output.dependencies.add(file.uri);
    return file;
  }

  // 2. Local build inside this package.
  final localDir = input.packageRoot.resolve('native/out/${target.name}/');
  output.dependencies.add(
    [
      localDir,
      input.packageRoot.resolve('native/out/'),
      input.packageRoot.resolve('native/'),
    ].firstWhere((uri) => Directory.fromUri(uri).existsSync()),
  );
  final local = File.fromUri(localDir.resolve(target.libraryFileName));
  if (local.existsSync()) {
    log('using local build ${local.path}');
    output.dependencies.add(local.uri);
    return local;
  }

  // 3. Download.
  final manifestUri = input.packageRoot.resolve('native/manifest.json');
  output.dependencies.add(manifestUri);
  final manifest = NativeManifest.load(File.fromUri(manifestUri));
  final entry = manifest.targets[target.name];
  if (entry == null || manifest.baseUrl == null) {
    _unavailable(
      input,
      log,
      'this version of image_transform has no prebuilt libvips for '
      '${target.name}',
    );
    return null;
  }
  if (input.userDefines['allow_download'] == false) {
    _unavailable(input, log, 'downloading is disabled (allow_download: false)');
    return null;
  }
  final mirror = input.userDefines['download_base_url'];
  var baseUrl = mirror is String ? mirror : manifest.baseUrl!;
  if (!baseUrl.endsWith('/')) baseUrl = '$baseUrl/';
  final shared = Directory.fromUri(input.outputDirectoryShared);
  final fetcher = LibraryFetcher(
    cacheDirectory: Directory(
      '${shared.path}${manifest.release ?? 'unversioned'}'
      '${Platform.pathSeparator}${target.name}',
    ),
    baseUrl: Uri.parse(baseUrl),
    log: log,
  );
  try {
    return await fetcher.fetch(entry);
  } on LibraryChecksumException {
    rethrow;
  } on Exception catch (e) {
    _unavailable(input, log, 'downloading libvips failed ($e)');
    return null;
  }
}
