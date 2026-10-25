import 'dart:io';
import 'dart:typed_data';

import 'package:image_transform/src/ffi/vips.dart';
import 'package:image_transform/src/types.dart';

/// Whether the bundled libvips is loadable in this test run.
final bool ffiAvailable = () {
  try {
    vipsVersionString();
    initVips(allowedFormats: ImageFormat.values.toSet());
    return true;
  } catch (_) {
    return false;
  }
}();

/// Header fields of encoded [bytes], as `vipsheader -a` prints them.
Map<String, String> header(Uint8List bytes) {
  if (ffiAvailable) return headerOfBytes(bytes) ?? const {};
  final dir = Directory.systemTemp.createTempSync('image_transform_test_');
  try {
    final file = File('${dir.path}/image')..writeAsBytesSync(bytes);
    final result = Process.runSync('vipsheader', ['-a', file.path]);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
    final fields = <String, String>{};
    for (final line in '${result.stdout}'.split('\n').skip(1)) {
      final i = line.indexOf(': ');
      if (i > 0) fields[line.substring(0, i)] = line.substring(i + 2).trim();
    }
    return fields;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Pixel values at ([x], [y]) of frame [page] of encoded [bytes].
List<int> pixel(Uint8List bytes, int page, int x, int y) {
  if (ffiAvailable) {
    final blob = VipsBlob.copy(bytes);
    try {
      final loader = findLoader(blob)!;
      final image = loadHeader(blob, loader, options: 'page=$page');
      try {
        return runOperation(
          'getpoint',
          args: {'in': image},
          options: 'x=$x,y=$y',
          read: (op, arena) => readDoubles(op, arena, 'out_array'),
        ).map((v) => v.round()).toList();
      } finally {
        image.dispose();
      }
    } finally {
      blob.dispose();
    }
  }
  final dir = Directory.systemTemp.createTempSync('image_transform_test_');
  try {
    final file = File('${dir.path}/image.webp')..writeAsBytesSync(bytes);
    final result = Process.runSync('vips', [
      'getpoint',
      '${file.path}[page=$page]',
      '$x',
      '$y',
    ]);
    return '${result.stdout}'.trim().split(' ').map(int.parse).toList();
  } finally {
    dir.deleteSync(recursive: true);
  }
}
