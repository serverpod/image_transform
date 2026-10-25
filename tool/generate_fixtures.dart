// Regenerates test/fixtures/ using the libvips CLI (`vips` >= 8.15 on PATH).
//
//   dart run tool/generate_fixtures.dart
//
// The fixtures are committed; run this only to change them.
import 'dart:io';
import 'dart:typed_data';

late Directory _work;
late Directory _out;

Future<void> main() async {
  _out = Directory('test/fixtures')..createSync(recursive: true);
  _work = Directory.systemTemp.createTempSync('image_transform_fixtures_');
  try {
    // A colourful 400x300 gradient (x → red, y → green, constant blue).
    await _vips(['xyz', 'xy.v', '400', '300']);
    await _vips(['linear', 'xy.v', 'rg.v', '0.6375 0.85', '0 0', '--uchar']);
    await _vips(['black', 'b.v', '400', '300']);
    await _vips(['linear', 'b.v', 'blue.v', '1', '96', '--uchar']);
    await _vips(['bandjoin', 'rg.v blue.v', 'rgb.v']);
    await _vips(['copy', 'rgb.v', 'srgb.v', '--interpretation', 'srgb']);

    await _vips(['copy', 'srgb.v', _fixture('landscape.jpg', '[Q=85]')]);
    for (final orientation in [3, 6, 8]) {
      final bytes = File('${_out.path}/landscape.jpg').readAsBytesSync();
      File(
        '${_out.path}/orientation-$orientation.jpg',
      ).writeAsBytesSync(_withOrientation(bytes, orientation));
    }
    await _vips(['thumbnail', 'srgb.v', 'small.v', '200']);
    await _vips([
      'icc_export',
      'small.v',
      'cmyk.v',
      '--output-profile',
      'cmyk',
    ]);
    await _vips(['copy', 'cmyk.v', _fixture('cmyk.jpg', '[Q=80,keep=none]')]);

    // RGBA PNG: the gradient with a horizontal alpha ramp.
    await _vips(['extract_band', 'xy.v', 'x.v', '0']);
    await _vips(['linear', 'x.v', 'alpha.v', '0.6375', '0', '--uchar']);
    await _vips(['bandjoin', 'srgb.v alpha.v', 'rgba.v']);
    await _vips(['thumbnail', 'rgba.v', _fixture('alpha.png'), '200']);
    await _vips(['colourspace', 'small.v', 'g16.v', 'grey16']);
    await _vips(['copy', 'g16.v', _fixture('grey16.png')]);
    await _vips([
      'copy',
      'srgb.v',
      _fixture('palette.png', '[palette=true,bitdepth=4]'),
    ]);
    await _vips(['black', 'one.v', '1', '1', '--bands', '3']);
    await _vips(['copy', 'one.v', _fixture('tiny.png')]);
    await _vips([
      'thumbnail',
      'srgb.v',
      _fixture('lossless.webp', '[lossless=true]'),
      '200',
    ]);

    // Animations: four 200x100 frames (red, green, blue, yellow), stacked.
    await _vips(['black', 'f.v', '200', '100', '--bands', '3']);
    const colours = ['255 0 0', '0 255 0', '0 0 255', '255 255 0'];
    for (var i = 0; i < colours.length; i++) {
      await _vips(['linear', 'f.v', 'f$i.v', '1 1 1', colours[i], '--uchar']);
    }
    await _vips([
      'arrayjoin',
      'f0.v f1.v f2.v f3.v',
      'stack.v',
      '--across',
      '1',
    ]);
    await _vips([
      'copy',
      'stack.v',
      _fixture('animated.gif', '[page_height=100]'),
    ]);
    await _vips([
      'copy',
      'stack.v',
      _fixture('animated.webp', '[page_height=100,Q=80]'),
    ]);
    await _vips(['copy', 'f0.v', _fixture('single-frame.gif')]);

    // Truncated JPEG: a noisy (incompressible) image cut at 60%.
    await _vips(['gaussnoise', 'n.v', '400', '300']);
    await _vips(['cast', 'n.v', 'nu.v', 'uchar']);
    await _vips(['bandjoin', 'nu.v nu.v nu.v', 'noise.v']);
    await _vips(['copy', 'noise.v', 'noise.jpg[Q=90]']);
    final noise = File('${_work.path}/noise.jpg').readAsBytesSync();
    File(
      '${_out.path}/truncated.jpg',
    ).writeAsBytesSync(noise.sublist(0, noise.length * 6 ~/ 10));

    // Formats that must be rejected.
    await _vips(['thumbnail', 'srgb.v', _fixture('image.tif'), '64']);
    File('${_out.path}/image.svg').writeAsStringSync(
      '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30">'
      '<rect width="40" height="30" fill="red"/></svg>\n',
    );
    File(
      '${_out.path}/not-an-image.jpg',
    ).writeAsStringSync('This is not an image.\n');
    File('${_out.path}/bomb.png').writeAsBytesSync(_pngBomb(50000, 50000));

    stdout.writeln('Fixtures written to ${_out.path}');
  } finally {
    _work.deleteSync(recursive: true);
  }
}

/// An output path in the fixtures directory, relative to the work directory.
String _fixture(String name, [String options = '']) =>
    '${File('${_out.path}/$name').absolute.path}$options';

Future<void> _vips(List<String> args) async {
  final result = await Process.run('vips', args, workingDirectory: _work.path);
  if (result.exitCode != 0) {
    throw StateError('vips ${args.join(' ')} failed: ${result.stderr}');
  }
}

/// Rewrites the EXIF orientation tag (0x0112) of a JPEG that already has one.
Uint8List _withOrientation(Uint8List jpeg, int orientation) {
  final bytes = Uint8List.fromList(jpeg);
  final data = ByteData.sublistView(bytes);
  const exifHeader = [0x45, 0x78, 0x69, 0x66, 0, 0]; // "Exif\0\0"
  for (var i = 0; i < bytes.length - 6; i++) {
    var match = true;
    for (var j = 0; j < 6 && match; j++) {
      match = bytes[i + j] == exifHeader[j];
    }
    if (!match) continue;
    final tiff = i + 6;
    final endian = bytes[tiff] == 0x49 ? Endian.little : Endian.big;
    final ifd0 = tiff + data.getUint32(tiff + 4, endian);
    final count = data.getUint16(ifd0, endian);
    for (var e = 0; e < count; e++) {
      final entry = ifd0 + 2 + e * 12;
      if (data.getUint16(entry, endian) == 0x0112) {
        data.setUint16(entry + 8, orientation, endian);
        return bytes;
      }
    }
  }
  throw StateError('No EXIF orientation tag found');
}

/// A PNG that declares [width]×[height] but contains almost no data.
Uint8List _pngBomb(int width, int height) {
  final out = BytesBuilder();
  out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2); // colour type: RGB
  _chunk(out, 'IHDR', ihdr.buffer.asUint8List());
  _chunk(out, 'IDAT', ZLibEncoder().convert(Uint8List(1024)));
  _chunk(out, 'IEND', Uint8List(0));
  return out.toBytes();
}

void _chunk(BytesBuilder out, String type, List<int> data) {
  final typeBytes = type.codeUnits;
  out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
  out.add(typeBytes);
  out.add(data);
  final crc = _crc32([...typeBytes, ...data]);
  out.add((ByteData(4)..setUint32(0, crc)).buffer.asUint8List());
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
