/// Native targets with prebuilt libvips, and their sharp-libvips sources.
library;

// Internal to the build hook and the release tools.
// ignore_for_file: public_member_api_docs

import 'dart:io';

/// Operating systems with prebuilt libvips.
enum NativeOS { macos, linux, windows }

/// CPU architectures with prebuilt libvips.
enum NativeArch { x64, arm64 }

/// One prebuilt target, e.g. `linux-musl-arm64`.
final class NativeTarget {
  const NativeTarget(this.os, this.arch, {this.musl = false});

  final NativeOS os;
  final NativeArch arch;

  /// Linux with musl libc (Alpine) instead of glibc.
  final bool musl;

  /// Every target the release publishes.
  static const all = [
    NativeTarget(NativeOS.macos, NativeArch.arm64),
    NativeTarget(NativeOS.macos, NativeArch.x64),
    NativeTarget(NativeOS.linux, NativeArch.x64),
    NativeTarget(NativeOS.linux, NativeArch.arm64),
    NativeTarget(NativeOS.linux, NativeArch.x64, musl: true),
    NativeTarget(NativeOS.linux, NativeArch.arm64, musl: true),
    NativeTarget(NativeOS.windows, NativeArch.x64),
    NativeTarget(NativeOS.windows, NativeArch.arm64),
  ];

  /// e.g. `macos-arm64`, `linux-musl-x64`.
  String get name => '${os.name}${musl ? '-musl' : ''}-${arch.name}';

  /// The library's file name inside a target directory.
  String get libraryFileName => switch (os) {
    NativeOS.macos => 'libvips.dylib',
    NativeOS.linux => 'libvips.so',
    NativeOS.windows => 'libvips.dll',
  };

  /// Platform suffix of the `@img/sharp-libvips-<platform>` npm package.
  String get sharpPlatform => switch ((os, musl)) {
    (NativeOS.macos, _) => 'darwin-${arch.name}',
    (NativeOS.linux, false) => 'linux-${arch.name}',
    (NativeOS.linux, true) => 'linuxmusl-${arch.name}',
    (NativeOS.windows, _) => 'win32-${arch.name}',
  };

  /// Path of the library inside the sharp-libvips npm tarball, given the
  /// libvips [vipsVersion] it ships.
  String sharpLibraryPath(String vipsVersion) => switch (os) {
    NativeOS.macos => 'package/lib/libvips-cpp.$vipsVersion.dylib',
    NativeOS.linux => 'package/lib/libvips-cpp.so.$vipsVersion',
    NativeOS.windows => 'package/lib/libvips-42.dll',
  };

  /// Library names to try for a system-installed libvips
  /// (`libvips: system`).
  List<String> get systemLibraryNames => switch (os) {
    NativeOS.macos => const [
      '/opt/homebrew/lib/libvips.42.dylib',
      '/usr/local/lib/libvips.42.dylib',
      'libvips.42.dylib',
    ],
    NativeOS.linux => const ['libvips.so.42'],
    NativeOS.windows => const ['libvips-42.dll'],
  };

  static NativeTarget? byName(String name) {
    for (final t in all) {
      if (t.name == name) return t;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is NativeTarget &&
      other.os == os &&
      other.arch == arch &&
      other.musl == musl;

  @override
  int get hashCode => Object.hash(os, arch, musl);

  @override
  String toString() => name;
}

/// Whether the machine running this code uses musl libc (Alpine).
///
/// Build hooks have no libc information in their config, so a Linux build
/// is assumed to target the libc of the build host. Cross-libc builds can
/// point `library_dir` at the right library.
bool hostUsesMusl() {
  if (!Platform.isLinux) return false;
  for (final name in const [
    '/lib/ld-musl-x86_64.so.1',
    '/lib/ld-musl-aarch64.so.1',
  ]) {
    if (File(name).existsSync()) return true;
  }
  return false;
}
