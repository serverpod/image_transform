import 'package:meta/meta.dart';

import 'types.dart';

/// Parses `vipsheader -a` output into fields. The first line
/// (`file: WxH …` summary) is skipped; values may contain `: `.
@internal
Map<String, String> parseVipsHeader(String output) {
  final fields = <String, String>{};
  final lines = output.split('\n');
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trimRight();
    final colon = line.indexOf(': ');
    if (colon <= 0) continue;
    fields.putIfAbsent(
      line.substring(0, colon),
      () => line.substring(colon + 2),
    );
  }
  return fields;
}

/// Maps a libvips loader nickname to a format.
@internal
ImageFormat formatForLoader(String loader) {
  if (loader.startsWith('jpegload')) return ImageFormat.jpeg;
  if (loader.startsWith('pngload')) return ImageFormat.png;
  if (loader.startsWith('webpload')) return ImageFormat.webp;
  if (loader.startsWith('gifload')) return ImageFormat.gif;
  return ImageFormat.other;
}

/// Builds [ImageInfo] from parsed header [fields].
@internal
ImageInfo imageInfoFromHeader(Map<String, String> fields, {int? byteLength}) {
  int intField(String name, int fallback) =>
      int.tryParse(fields[name]?.split(' ').first ?? '') ?? fallback;
  final loader = fields['vips-loader'] ?? 'unknown';
  final interpretation = fields['interpretation'] ?? '';
  final bands = intField('bands', 3);
  final colorSpace = switch (interpretation) {
    'srgb' || 'rgb' || 'scrgb' => ColorSpace.srgb,
    'rgb16' => ColorSpace.rgb16,
    'b-w' => ColorSpace.grey,
    'grey16' => ColorSpace.grey16,
    'cmyk' => ColorSpace.cmyk,
    'lab' || 'labs' || 'labq' => ColorSpace.lab,
    _ => ColorSpace.other,
  };
  final hasAlpha = colorSpace == ColorSpace.cmyk
      ? bands >= 5
      : bands == 2 || bands >= 4;
  final orientation = intField('orientation', 1);
  return ImageInfo(
    format: formatForLoader(loader),
    loader: loader,
    width: intField('width', 0),
    height: intField('page-height', intField('height', 0)),
    orientation: orientation >= 1 && orientation <= 8 ? orientation : 1,
    frames: intField('n-pages', 1),
    hasAlpha: hasAlpha,
    colorSpace: colorSpace,
    hasIccProfile: fields.containsKey('icc-profile-data'),
    byteLength: byteLength,
  );
}

/// Parses a libvips version from `vips --version` output (`vips-8.17.2 …`).
@internal
({int major, int minor, int patch})? parseVipsVersion(String output) {
  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(output);
  if (match == null) return null;
  return (
    major: int.parse(match[1]!),
    minor: int.parse(match[2]!),
    patch: int.parse(match[3]!),
  );
}

final _absolutePath = RegExp(
  r'''(?:[A-Za-z]:)?[\\/](?:[^\s:"'\\/]+[\\/])+[^\s:"'\\/]*''',
);
final _vipsWarning = RegExp(r'^\(vips:\d+\): VIPS-WARNING \*\*: [\d:.]+: ');

/// Makes libvips stderr safe to show: replaces [knownPaths] and any other
/// absolute paths with placeholders, drops GLib warning prefixes and blank
/// lines, and caps the length at 1 KiB.
@internal
String sanitizeVipsError(
  String stderr, {
  Map<String, String> knownPaths = const {},
}) {
  var text = stderr;
  knownPaths.forEach((path, placeholder) {
    if (path.isNotEmpty) text = text.replaceAll(path, placeholder);
  });
  text = text
      .split('\n')
      .map((line) => line.replaceFirst(_vipsWarning, '').trim())
      .where((line) => line.isNotEmpty)
      .join('\n')
      .replaceAll(_absolutePath, '<path>');
  return text.length > 1024 ? '${text.substring(0, 1021)}...' : text;
}

final _decodeError = RegExp(
  r'load|VipsJpeg|VipsPng|libspng|libpng|nsgif|VipsGif|premature end|corrupt|truncat|not a known file format',
  caseSensitive: false,
);

/// Whether libvips [stderr] describes a problem reading the source (rather
/// than encoding or writing an output).
@internal
bool looksLikeDecodeError(String stderr) {
  // Only the final error lines matter; earlier lines may be warnings.
  final errors = stderr
      .split('\n')
      .where((l) => l.trim().isNotEmpty && !l.contains('VIPS-WARNING'))
      .join('\n');
  return _decodeError.hasMatch(errors) && !errors.contains('save');
}
