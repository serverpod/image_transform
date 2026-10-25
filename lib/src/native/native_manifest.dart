/// `native/manifest.json`: where this package version's prebuilt libvips
/// libraries are published, and their hashes.
library;

// Internal to the build hook and the release tools.
// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

/// The prebuilt library of one target.
final class ManifestEntry {
  const ManifestEntry({
    required this.file,
    required this.asset,
    required this.sha256,
    required this.size,
  });

  /// File name of the uncompressed library, e.g. `libvips.so`.
  final String file;

  /// Name of the gzip-compressed release asset, e.g. `linux-x64-libvips.so.gz`.
  final String asset;

  /// Hex SHA-256 of the uncompressed library.
  final String sha256;

  /// Size of the uncompressed library in bytes.
  final int size;

  factory ManifestEntry.fromJson(Map<String, Object?> json) => ManifestEntry(
    file: json['file']! as String,
    asset: json['asset']! as String,
    sha256: json['sha256']! as String,
    size: json['size']! as int,
  );

  Map<String, Object?> toJson() => {
    'file': file,
    'asset': asset,
    'sha256': sha256,
    'size': size,
  };
}

/// The parsed manifest.
final class NativeManifest {
  const NativeManifest({
    required this.release,
    required this.baseUrl,
    required this.vipsVersion,
    required this.targets,
  });

  /// Git tag of the GitHub release holding the files, e.g. `native-v0.1.0`.
  final String? release;

  /// URL the asset names are resolved against.
  final String? baseUrl;

  /// libvips version of the published libraries.
  final String? vipsVersion;

  /// Library per target name (`linux-x64`, …).
  final Map<String, ManifestEntry> targets;

  static NativeManifest load(File file) =>
      parse(jsonDecode(file.readAsStringSync()) as Map<String, Object?>);

  static NativeManifest parse(Map<String, Object?> json) {
    final raw = (json['targets'] as Map<String, Object?>?) ?? const {};
    return NativeManifest(
      release: json['release'] as String?,
      baseUrl: json['baseUrl'] as String?,
      vipsVersion: json['vipsVersion'] as String?,
      targets: {
        for (final MapEntry(:key, :value) in raw.entries)
          key: ManifestEntry.fromJson(value! as Map<String, Object?>),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'release': release,
    'baseUrl': baseUrl,
    'vipsVersion': vipsVersion,
    'targets': {
      for (final MapEntry(:key, :value) in targets.entries) key: value.toJson(),
    },
  };
}
