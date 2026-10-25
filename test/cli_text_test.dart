import 'dart:convert';
import 'dart:typed_data';

import 'package:image_transform/image_transform.dart';
import 'package:image_transform/src/cli_args.dart';
import 'package:image_transform/src/planning.dart';
import 'package:image_transform/src/vips_text.dart';
import 'package:test/test.dart';

// Captured from `vipsheader -a` (libvips 8.18).
const _jpegHeader = '''
source: 400x300 uchar, 3 bands, srgb, jpegload
width: 400
height: 300
bands: 3
format: uchar
coding: none
interpretation: srgb
filename: source
vips-loader: jpegload
exif-data: 186 bytes of binary data
exif-ifd0-Orientation: 6 (Right-top, Short, 1 components, 2 bytes)
orientation: 6
icc-profile-data: 3144 bytes of binary data
''';

const _gifHeader = '''
source: 200x100 uchar, 4 bands, srgb, gifload
width: 200
height: 100
bands: 4
interpretation: srgb
vips-loader: gifload
n-pages: 4
loop: 0
delay: 100 100 100 100
''';

void main() {
  group('vipsheader parsing', () {
    test('JPEG with orientation and ICC', () {
      final info = imageInfoFromHeader(
        parseVipsHeader(_jpegHeader),
        byteLength: 42,
      );
      expect(info.format, ImageFormat.jpeg);
      expect(info.loader, 'jpegload');
      expect((info.width, info.height), (400, 300));
      expect((info.orientedWidth, info.orientedHeight), (300, 400));
      expect(info.orientation, 6);
      expect(info.frames, 1);
      expect(info.hasAlpha, isFalse);
      expect(info.colorSpace, ColorSpace.srgb);
      expect(info.hasIccProfile, isTrue);
      expect(info.byteLength, 42);
    });

    test('animated GIF with alpha', () {
      final info = imageInfoFromHeader(parseVipsHeader(_gifHeader));
      expect(info.format, ImageFormat.gif);
      expect(info.frames, 4);
      expect(info.hasAlpha, isTrue);
      expect(info.orientation, 1);
    });

    test('values containing ": " are kept whole', () {
      final fields = parseVipsHeader('x: summary\nexif-ifd0-Artist: a: b\n');
      expect(fields['exif-ifd0-Artist'], 'a: b');
    });

    test('loaders, colour spaces and alpha', () {
      expect(formatForLoader('pngload_source'), ImageFormat.png);
      expect(formatForLoader('webpload'), ImageFormat.webp);
      expect(formatForLoader('svgload'), ImageFormat.other);
      ImageInfo parse(String fields) =>
          imageInfoFromHeader(parseVipsHeader('s: x\n$fields'));
      expect(parse('bands: 4\ninterpretation: cmyk').hasAlpha, isFalse);
      expect(parse('bands: 5\ninterpretation: cmyk').hasAlpha, isTrue);
      expect(parse('bands: 2\ninterpretation: b-w').hasAlpha, isTrue);
      expect(
        parse('bands: 1\ninterpretation: grey16').colorSpace,
        ColorSpace.grey16,
      );
      expect(parse('bands: 3\ninterpretation: lab').colorSpace, ColorSpace.lab);
      expect(parse('orientation: 42').orientation, 1);
    });

    test('version', () {
      expect(parseVipsVersion('vips-8.18.7'), (major: 8, minor: 18, patch: 7));
      expect(parseVipsVersion('vips-8.15.0-Tue Jan 1'), (
        major: 8,
        minor: 15,
        patch: 0,
      ));
      expect(parseVipsVersion('nope'), isNull);
    });
  });

  group('stderr handling', () {
    test('sanitises paths, warnings and length', () {
      const stderr = '''

(vips:82809): VIPS-WARNING **: 21:24:43.401: error in tile 0 x 88
VipsJpeg: premature end of JPEG image in /var/folders/ab/cd/T/image_transform_x/source
C:\\Users\\Jane Doe\\file.jpg is broken
''';
      final clean = sanitizeVipsError(
        stderr,
        knownPaths: {'/var/folders/ab/cd/T/image_transform_x': '<tmp>'},
      );
      expect(clean, contains('<tmp>/source'));
      expect(clean, isNot(contains('/var/folders')));
      expect(clean, isNot(contains('VIPS-WARNING')));
      expect(clean, isNot(contains('Users')));
      expect(sanitizeVipsError('x' * 5000).length, 1024);
    });

    test('decode vs encode errors', () {
      expect(
        looksLikeDecodeError('VipsJpeg: premature end of JPEG image'),
        isTrue,
      );
      expect(
        looksLikeDecodeError('VipsForeignLoad: "x" is not a known file format'),
        isTrue,
      );
      expect(looksLikeDecodeError('webpsave: unable to encode'), isFalse);
      expect(
        looksLikeDecodeError(
          '(vips:1): VIPS-WARNING **: 1:2:3: VipsJpeg: warning\nvips_image_write: bad',
        ),
        isFalse,
      );
    });
  });

  group('CLI arguments', () {
    test('load options only for multi-frame formats', () {
      expect(CliArgs.loadOptions(ImageFormat.jpeg, allFrames: true), '');
      expect(CliArgs.loadOptions(ImageFormat.gif, allFrames: true), '[n=-1]');
      expect(CliArgs.loadOptions(ImageFormat.webp, allFrames: false), '[n=1]');
    });

    test('save options per encoder', () {
      expect(
        CliArgs.saveOptions(const Encode.webp(), MetadataPolicy.none),
        '[Q=80,lossless=false,effort=4,smart_subsample=true,alpha_q=100,keep=none]',
      );
      expect(
        CliArgs.saveOptions(
          const Encode.jpeg(subsampling: ChromaSubsampling.yuv444),
          MetadataPolicy.icc,
        ),
        '[Q=82,interlace=true,optimize_coding=true,subsample_mode=off,background=255,keep=icc]',
      );
      expect(
        CliArgs.saveOptions(
          const Encode.png(palette: true, colors: 16),
          MetadataPolicy.all,
        ),
        '[compression=6,palette=true,bitdepth=4,keep=all]',
      );
      expect(
        CliArgs.saveOptions(
          const Encode.webp(lossless: true),
          MetadataPolicy.none,
          pageHeight: 80,
        ),
        endsWith(',keep=none,page_height=80]'),
      );
    });

    ImageInfo info({ImageFormat format = ImageFormat.jpeg, int frames = 1}) =>
        ImageInfo(
          format: format,
          loader: '${format.name}load',
          width: 4000,
          height: 3000,
          orientation: 1,
          frames: frames,
          hasAlpha: false,
          colorSpace: ColorSpace.srgb,
          hasIccProfile: false,
        );

    List<String> args(
      ImageOutput output, {
      TransformOptions options = const TransformOptions(),
      ImageInfo? source,
      bool manual = false,
    }) {
      final src = source ?? info();
      return CliArgs.renderStep(
        planOutput(src, output, options),
        src,
        sourcePath: 'source',
        output: 'out-0.webp',
        intermediate: 'tmp-0.v',
        options: options,
        needsManualCrop: manual,
      );
    }

    const save =
        '[Q=80,lossless=false,effort=4,smart_subsample=true,alpha_q=100,keep=none]';

    test('fit', () {
      expect(
        args(const ImageOutput(name: 'a', resize: Resize.fit(width: 640))),
        [
          'thumbnail',
          'source',
          'out-0.webp$save',
          '640',
          '--height',
          '10000000',
          '--size',
          'down',
          '--export-profile',
          'srgb',
          '--fail-on',
          'error',
        ],
      );
      expect(
        args(
          const ImageOutput(
            name: 'a',
            resize: Resize.fit(height: 300, upscale: true),
          ),
        ),
        [
          'thumbnail',
          'source',
          'out-0.webp$save',
          '10000000',
          '--height',
          '300',
          '--size',
          'both',
          '--export-profile',
          'srgb',
          '--fail-on',
          'error',
        ],
      );
    });

    test('cover with libvips crop', () {
      expect(
        args(
          const ImageOutput(
            name: 'a',
            resize: Resize.cover(256, 256, crop: Crop.attention()),
          ),
        ),
        [
          'thumbnail',
          'source',
          'out-0.webp$save',
          '256',
          '--height',
          '256',
          '--size',
          'down',
          '--crop',
          'attention',
          '--export-profile',
          'srgb',
          '--fail-on',
          'error',
        ],
      );
    });

    test('focal cover resizes with force into an intermediate', () {
      expect(
        args(
          const ImageOutput(
            name: 'a',
            resize: Resize.cover(256, 256, crop: Crop.focal(0.3, 0.3)),
          ),
          manual: true,
        ),
        [
          'thumbnail',
          'source',
          'tmp-0.v',
          '342',
          '--height',
          '256',
          '--size',
          'force',
          '--export-profile',
          'srgb',
          '--fail-on',
          'error',
        ],
      );
      expect(CliArgs.extractArea('tmp-0.v', 'out.webp', 1, 2, 3, 4), [
        'extract_area',
        'tmp-0.v',
        'out.webp',
        '1',
        '2',
        '3',
        '4',
      ]);
    });

    test('animated GIF loads all frames', () {
      expect(
        args(
          const ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
          source: info(format: ImageFormat.gif, frames: 4),
        )[1],
        'source[n=-1]',
      );
    });

    test('options map to flags', () {
      final a = args(
        const ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
        options: const TransformOptions(
          autoOrient: false,
          color: ColorPolicy.preserve,
          failOn: FailOn.none,
        ),
      );
      expect(a, containsAllInOrder(['--no-rotate', '--fail-on', 'none']));
      expect(a, isNot(contains('--export-profile')));
    });
  });

  group('results', () {
    test('lookup by name', () {
      final result = TransformResult(
        source: info0,
        elapsed: Duration.zero,
        outputs: [
          OutputSuccess(
            name: 'ok',
            width: 1,
            height: 1,
            frames: 1,
            byteLength: 1,
            format: ImageFormat.webp,
            clamped: false,
          ),
          const OutputFailure(name: 'bad', error: EncodeException('nope')),
        ],
      );
      expect(result['ok'].width, 1);
      expect(() => result['bad'], throwsA(isA<EncodeException>()));
      expect(() => result['missing'], throwsArgumentError);
      expect(result.allSucceeded, isFalse);
      expect(result.successes.map((s) => s.name), ['ok']);
      expect(result.failures.map((s) => s.name), ['bad']);
    });

    test('placeholder data URI', () {
      final p = Placeholder(
        bytes: Uint8List.fromList(utf8.encode('hi')),
        width: 1,
        height: 1,
        format: ImageFormat.webp,
      );
      expect(p.dataUri, 'data:image/webp;base64,aGk=');
    });
  });
}

const info0 = ImageInfo(
  format: ImageFormat.jpeg,
  loader: 'jpegload',
  width: 1,
  height: 1,
  orientation: 1,
  frames: 1,
  hasAlpha: false,
  colorSpace: ColorSpace.srgb,
  hasIccProfile: false,
);
