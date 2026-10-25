// Downloads the pinned sharp-libvips builds (native/sharp_libvips.json),
// verifies their npm SHA-512 integrity, and extracts each library to
// native/out/<target>/ together with a build-info.json.
//
//   dart run tool/fetch_sharp_libvips.dart                  # host target
//   dart run tool/fetch_sharp_libvips.dart --target linux-x64
//   dart run tool/fetch_sharp_libvips.dart --all
//
// native/out/<target>/ is picked up by the build hook, so after this
// `dart test` uses the fetched library.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image_transform/src/native/library_fetcher.dart';
import 'package:image_transform/src/native/native_targets.dart';

Future<void> main(List<String> args) async {
  final pins =
      jsonDecode(File('native/sharp_libvips.json').readAsStringSync())
          as Map<String, Object?>;
  final packages = pins['packages']! as Map<String, Object?>;
  final vipsVersion = pins['vipsVersion']! as String;

  final List<NativeTarget> targets;
  if (args.contains('--all')) {
    targets = NativeTarget.all;
  } else if (args.contains('--target')) {
    final name = args[args.indexOf('--target') + 1];
    targets = [
      NativeTarget.byName(name) ??
          (throw ArgumentError('Unknown target $name')),
    ];
  } else {
    targets = [_hostTarget()];
  }

  for (final target in targets) {
    final pin = packages[target.sharpPlatform]! as Map<String, Object?>;
    final tarball = Uri.parse(pin['tarball']! as String);
    final integrity = pin['integrity']! as String;
    stdout.writeln('${target.name}: $tarball');

    final bytes = await _download(tarball);
    final expected = integrity.replaceFirst('sha512-', '');
    final actual = base64.encode(sha512.convert(bytes).bytes);
    if (actual != expected) {
      throw StateError('Integrity mismatch for $tarball');
    }

    final temp = await Directory.systemTemp.createTemp('sharp_libvips_');
    try {
      final archive = File('${temp.path}/package.tgz')..writeAsBytesSync(bytes);
      final inner = target.sharpLibraryPath(vipsVersion);
      final result = await Process.run('tar', [
        '-xzf',
        archive.path,
        '-C',
        temp.path,
        inner,
        'package/package.json',
        'package/versions.json',
      ]);
      if (result.exitCode != 0) {
        throw StateError('tar failed: ${result.stderr}');
      }
      final out = Directory('native/out/${target.name}');
      await out.create(recursive: true);
      final library = File('${out.path}/${target.libraryFileName}');
      await File('${temp.path}/$inner').copy(library.path);
      final versions = jsonDecode(
        File('${temp.path}/package/versions.json').readAsStringSync(),
      );
      final info = {
        'target': target.name,
        'library': target.libraryFileName,
        'sha256': await sha256OfFile(library),
        'size': await library.length(),
        'vipsVersion': vipsVersion,
        'source': {
          'package': '@img/sharp-libvips-${target.sharpPlatform}',
          'version': pins['sharpLibvipsVersion'],
          'tarball': tarball.toString(),
          'integrity': integrity,
          'license': pins['license'],
          'buildScripts': pins['source'],
        },
        'components': versions,
      };
      await File(
        '${out.path}/build-info.json',
      ).writeAsString('${const JsonEncoder.withIndent('  ').convert(info)}\n');
      stdout.writeln('  -> ${library.path} (${info['size']} bytes)');
    } finally {
      await temp.delete(recursive: true);
    }
  }
}

NativeTarget _hostTarget() {
  final arch = switch (Abi.current()) {
    Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => NativeArch.arm64,
    _ => NativeArch.x64,
  };
  final os = Platform.isMacOS
      ? NativeOS.macos
      : Platform.isWindows
      ? NativeOS.windows
      : NativeOS.linux;
  return NativeTarget(os, arch, musl: hostUsesMusl());
}

Future<List<int>> _download(Uri url) async {
  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    for (var attempt = 1; ; attempt++) {
      try {
        final response = await (await client.getUrl(url)).close();
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode}', uri: url);
        }
        return await response.fold<List<int>>([], (a, b) => a..addAll(b));
      } catch (e) {
        if (attempt >= 3) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  } finally {
    client.close(force: true);
  }
}
