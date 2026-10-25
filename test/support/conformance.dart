import 'dart:io';

import 'package:image_transform/image_transform.dart';
import 'package:test/test.dart';

import 'inspect.dart';

const _fixtures = 'test/fixtures';

ImageInput _fixture(String name) => ImageInput.file('$_fixtures/$name');

/// The conformance suite (specs/05 §5.2), run once per backend.
void runConformance(BackendPreference backend, BackendKind kind) {
  late ImageTransformer t;

  setUpAll(() async {
    t = await ImageTransformer.create(TransformerConfig(backend: backend));
  });
  tearDownAll(() => t.close());

  Future<OutputSuccess> one(
    String fixture,
    ImageOutput output, {
    TransformOptions options = const TransformOptions(),
  }) async {
    final result = await t.transform(_fixture(fixture), [
      output,
    ], options: options);
    return result[output.name];
  }

  test('backend info', () {
    expect(t.info.kind, kind);
    expect(t.info.vipsVersion, matches(RegExp(r'^8\.\d+\.\d+$')));
    expect(t.info.reasons, isNotEmpty);
  });

  group('probe', () {
    final cases = <String, (ImageFormat, int, int, int, int, bool)>{
      // fixture: format, width, height, orientation, frames, alpha
      'landscape.jpg': (ImageFormat.jpeg, 400, 300, 1, 1, false),
      'orientation-6.jpg': (ImageFormat.jpeg, 400, 300, 6, 1, false),
      'cmyk.jpg': (ImageFormat.jpeg, 200, 150, 1, 1, false),
      'alpha.png': (ImageFormat.png, 200, 150, 1, 1, true),
      'grey16.png': (ImageFormat.png, 200, 150, 1, 1, false),
      'tiny.png': (ImageFormat.png, 1, 1, 1, 1, false),
      'lossless.webp': (ImageFormat.webp, 200, 150, 1, 1, false),
      'animated.webp': (ImageFormat.webp, 200, 100, 1, 4, false),
      'animated.gif': (ImageFormat.gif, 200, 100, 1, 4, true),
    };
    cases.forEach((name, expected) {
      test(name, () async {
        final info = await t.probe(_fixture(name));
        expect((
          info.format,
          info.width,
          info.height,
          info.orientation,
          info.frames,
          info.hasAlpha,
        ), expected);
        expect(info.byteLength, File('$_fixtures/$name').lengthSync());
      });
    });

    test('colour spaces', () async {
      expect((await t.probe(_fixture('cmyk.jpg'))).colorSpace, ColorSpace.cmyk);
      expect(
        (await t.probe(_fixture('grey16.png'))).colorSpace,
        ColorSpace.grey16,
      );
    });
  });

  group('rejected input', () {
    test('not an image', () {
      expect(
        t.probe(_fixture('not-an-image.jpg')),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });
    test('SVG and TIFF are not allowed', () async {
      // svgload is an "untrusted" loader: VIPS_BLOCK_UNTRUSTED hides it
      // entirely, so the SVG isn't even recognised.
      await expectLater(
        t.transform(_fixture('image.svg'), const [ImageOutput(name: 'a')]),
        throwsA(isA<UnsupportedFormatException>()),
      );
      await expectLater(
        t.probe(_fixture('image.tif')),
        throwsA(
          isA<UnsupportedFormatException>().having(
            (e) => e.detectedLoader,
            'loader',
            // The FFI backend blocks non-allowed loaders, so it can't name it.
            anyOf(isNull, startsWith('tiffload')),
          ),
        ),
      );
    });
    test('decompression bomb fails on the header', () {
      expect(
        t.transform(_fixture('bomb.png'), const [
          ImageOutput(name: 'a', resize: Resize.fit(width: 10)),
        ]),
        throwsA(
          isA<SourceLimitsException>().having(
            (e) => e.limit,
            'limit',
            'maxPixels',
          ),
        ),
      );
    });
    test('truncated JPEG is a decode error', () {
      expect(
        t.transform(_fixture('truncated.jpg'), const [
          ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
        ]),
        throwsA(isA<DecodeException>()),
      );
    });
    test('truncated JPEG renders with FailOn.none', () async {
      final out = await one(
        'truncated.jpg',
        const ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
        options: const TransformOptions(failOn: FailOn.none),
      );
      expect(out.width, 100);
    });
    test('maxInputBytes for bytes and streams', () async {
      final bytes = File('$_fixtures/landscape.jpg').readAsBytesSync();
      const options = TransformOptions(
        limits: SourceLimits(maxInputBytes: 1000),
      );
      await expectLater(
        t.transform(ImageInput.bytes(bytes), const [
          ImageOutput(name: 'a'),
        ], options: options),
        throwsA(isA<SourceLimitsException>()),
      );
      await expectLater(
        t.transform(ImageInput.stream(Stream.value(bytes)), const [
          ImageOutput(name: 'a'),
        ], options: options),
        throwsA(isA<SourceLimitsException>()),
      );
    });
  });

  group('resize', () {
    test('fit, WebP, metadata stripped', () async {
      final out = await one(
        'landscape.jpg',
        const ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
      );
      expect(
        (out.width, out.height, out.format, out.clamped),
        (100, 75, ImageFormat.webp, false),
      );
      final fields = header(out.bytes!);
      expect(fields['vips-loader'], startsWith('webpload'));
      expect(fields.keys.where((k) => k.startsWith('exif')), isEmpty);
    });

    test('EXIF orientations are applied', () async {
      for (final (fixture, w, h) in [
        ('orientation-3.jpg', 100, 75),
        ('orientation-6.jpg', 100, 133),
        ('orientation-8.jpg', 100, 133),
      ]) {
        final out = await one(
          fixture,
          const ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
        );
        expect((out.width, out.height), (w, h), reason: fixture);
      }
      final raw = await one(
        'orientation-6.jpg',
        const ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
        options: const TransformOptions(autoOrient: false),
      );
      expect((raw.width, raw.height), (100, 75));
    });

    test('never upscales unless asked', () async {
      final clamped = await one(
        'landscape.jpg',
        const ImageOutput(name: 'a', resize: Resize.fit(width: 800)),
      );
      expect(
        (clamped.width, clamped.height, clamped.clamped),
        (400, 300, true),
      );
      final up = await one(
        'landscape.jpg',
        const ImageOutput(
          name: 'a',
          resize: Resize.fit(width: 800, upscale: true),
        ),
      );
      expect((up.width, up.height, up.clamped), (800, 600, false));
    });

    test('cover with every crop strategy', () async {
      for (final crop in const [
        Crop.centre(),
        Crop.attention(),
        Crop.entropy(),
        Crop.focal(0.9, 0.1),
      ]) {
        final out = await one(
          'landscape.jpg',
          ImageOutput(
            name: 'a',
            resize: Resize.cover(64, 48, crop: crop),
          ),
        );
        expect((out.width, out.height), (64, 48), reason: '$crop');
      }
    });

    test('cover clamps to the source keeping the aspect ratio', () async {
      final out = await one(
        'landscape.jpg',
        const ImageOutput(name: 'a', resize: Resize.cover(1000, 500)),
      );
      expect((out.width, out.height, out.clamped), (400, 200, true));
    });

    test('plan() matches the measured output', () async {
      final info = await t.probe(_fixture('orientation-6.jpg'));
      for (final output in const [
        ImageOutput(name: 'a', resize: Resize.fit(width: 123)),
        ImageOutput(name: 'b', resize: Resize.fit(height: 77)),
        ImageOutput(
          name: 'c',
          resize: Resize.cover(91, 33, crop: Crop.focal(0.3, 0.7)),
        ),
        ImageOutput(name: 'd'),
      ]) {
        final plan = t.plan(info, output);
        final out = await one('orientation-6.jpg', output);
        expect(
          (out.width - plan.width).abs(),
          lessThanOrEqualTo(1),
          reason: output.name,
        );
        expect(
          (out.height - plan.height).abs(),
          lessThanOrEqualTo(1),
          reason: output.name,
        );
      }
    });
  });

  group('encoders and colour', () {
    test('JPEG flattens alpha', () async {
      final out = await one(
        'alpha.png',
        const ImageOutput(name: 'a', encode: Encode.jpeg(quality: 80)),
      );
      final fields = header(out.bytes!);
      expect(fields['vips-loader'], startsWith('jpegload'));
      expect(fields['bands'], '3');
    });

    test('PNG keeps alpha, palette works', () async {
      final png = await one(
        'alpha.png',
        const ImageOutput(name: 'a', encode: Encode.png()),
      );
      expect(header(png.bytes!)['bands'], '4');
      final palette = await one(
        'landscape.jpg',
        const ImageOutput(
          name: 'a',
          encode: Encode.png(palette: true, colors: 16),
        ),
      );
      expect(header(palette.bytes!)['palette'], '1');
    });

    test('CMYK and 16-bit grey become 8-bit WebP', () async {
      final cmyk = await one('cmyk.jpg', const ImageOutput(name: 'a'));
      expect(header(cmyk.bytes!)['interpretation'], 'srgb');
      final grey = await one('grey16.png', const ImageOutput(name: 'a'));
      expect(header(grey.bytes!)['format'], 'uchar');
    });

    test('MetadataPolicy.all keeps EXIF with a reset orientation', () async {
      final out = await one(
        'orientation-6.jpg',
        const ImageOutput(name: 'a', encode: Encode.jpeg()),
        options: const TransformOptions(metadata: MetadataPolicy.all),
      );
      final fields = header(out.bytes!);
      expect(fields['orientation'], '1');
      expect(fields.keys.where((k) => k.startsWith('exif')), isNotEmpty);
    });
  });

  group('animation', () {
    for (final fixture in ['animated.gif', 'animated.webp']) {
      test('$fixture → animated WebP', () async {
        final out = await one(
          fixture,
          const ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
        );
        expect((out.width, out.height, out.frames), (100, 50, 4));
        expect(header(out.bytes!)['n-pages'], '4');
      });
    }

    test('cover crops every frame (column and row crops)', () async {
      for (final (w, h) in [(80, 80), (50, 100), (200, 50)]) {
        final out = await one(
          'animated.gif',
          ImageOutput(name: 'a', resize: Resize.cover(w, h)),
        );
        expect(
          (out.width, out.height, out.frames),
          (w, h, 4),
          reason: '${w}x$h',
        );
      }
    });

    test('cropped frames keep their own content', () async {
      // Frames are red, green, blue, yellow; a crop of the stacked image
      // instead of each frame would mix them up.
      const expected = ['255 0 0', '0 255 0', '0 0 255', '255 255 0'];
      for (final (w, h) in [(80, 80), (200, 50)]) {
        final out = await one(
          'animated.gif',
          ImageOutput(name: 'a', resize: Resize.cover(w, h)),
        );
        for (var i = 0; i < 4; i++) {
          final channels = pixel(out.bytes!, i, w ~/ 2, h ~/ 2);
          final want = expected[i].split(' ').map(int.parse).toList();
          for (var j = 0; j < want.length; j++) {
            expect(
              (channels[j] - want[j]).abs(),
              lessThan(8),
              reason: '${w}x$h frame $i',
            );
          }
        }
      }
    });

    test('stills: firstFrame, JPEG and focal crops', () async {
      final first = await one(
        'animated.gif',
        const ImageOutput(name: 'a'),
        options: const TransformOptions(animation: AnimationMode.firstFrame),
      );
      expect(first.frames, 1);
      final jpeg = await one(
        'animated.gif',
        const ImageOutput(name: 'a', encode: Encode.jpeg()),
      );
      expect(jpeg.frames, 1);
      final focal = await one(
        'animated.gif',
        const ImageOutput(
          name: 'a',
          resize: Resize.cover(50, 50, crop: Crop.focal(0.1, 0.1)),
        ),
      );
      expect((focal.width, focal.height, focal.frames), (50, 50, 1));
    });

    test('frame limits', () {
      expect(
        t.transform(_fixture('animated.gif'), const [
          ImageOutput(name: 'a'),
        ], options: const TransformOptions(limits: SourceLimits(maxFrames: 3))),
        throwsA(
          isA<SourceLimitsException>().having(
            (e) => e.limit,
            'limit',
            'maxFrames',
          ),
        ),
      );
    });
  });

  group('calls', () {
    test('many outputs and a placeholder from one call', () async {
      final result = await t.transform(_fixture('landscape.jpg'), [
        for (final w in [50, 100, 200])
          ImageOutput(
            name: 'w$w',
            resize: Resize.fit(width: w),
          ),
        const ImageOutput(
          name: 'avatar',
          resize: Resize.cover(32, 32, crop: Crop.attention()),
          encode: Encode.jpeg(),
        ),
      ], placeholder: const PlaceholderOptions());
      expect(result.allSucceeded, isTrue);
      expect(result.outputs.map((o) => o.name), [
        'w50',
        'w100',
        'w200',
        'avatar',
      ]);
      expect(result.source.format, ImageFormat.jpeg);
      final placeholder = result.placeholder!;
      expect((placeholder.width, placeholder.height), (24, 18));
      expect(placeholder.dataUri, startsWith('data:image/webp;base64,'));
      expect(placeholder.bytes.length, lessThan(1000));
    });

    test(
      'file targets are written atomically; odd input paths are safe',
      () async {
        final dir = Directory.systemTemp.createTempSync(
          'image transform [test], ',
        );
        try {
          final input = File('${dir.path}/my [weird], name.jpg');
          File('$_fixtures/landscape.jpg').copySync(input.path);
          final outPath = '${dir.path}/nested/out put.webp';
          final result = await t.transform(ImageInput.file(input.path), [
            ImageOutput(
              name: 'a',
              resize: const Resize.fit(width: 50),
              to: OutputTarget.file(outPath),
            ),
          ]);
          final out = result['a'];
          expect(out.path, outPath);
          expect(out.bytes, isNull);
          expect(File(outPath).lengthSync(), out.byteLength);
          expect(Directory('${dir.path}/nested').listSync(), hasLength(1));
        } finally {
          dir.deleteSync(recursive: true);
        }
      },
    );

    test('bytes and stream inputs', () async {
      final bytes = File('$_fixtures/landscape.jpg').readAsBytesSync();
      final fromBytes = await t.transform(ImageInput.bytes(bytes), const [
        ImageOutput(name: 'a', resize: Resize.fit(width: 10)),
      ]);
      expect(fromBytes['a'].width, 10);
      final fromStream = await t.transform(
        ImageInput.stream(
          Stream.fromIterable([bytes.sublist(0, 100), bytes.sublist(100)]),
        ),
        const [ImageOutput(name: 'a', resize: Resize.fit(width: 10))],
      );
      expect(fromStream['a'].width, 10);
    });

    test('temp files are cleaned up', () async {
      if (kind != BackendKind.cli) return markTestSkipped('CLI only');
      final base = Directory.systemTemp.createTempSync(
        'image_transform_cleanup_',
      );
      final scoped = await ImageTransformer.create(
        TransformerConfig(
          backend: BackendPreference.cli,
          tempDirectory: base.path,
        ),
      );
      try {
        await scoped.transform(_fixture('animated.gif'), const [
          ImageOutput(name: 'a', resize: Resize.cover(200, 50)),
        ]);
        await expectLater(
          scoped.transform(_fixture('truncated.jpg'), const [
            ImageOutput(name: 'a'),
          ]),
          throwsA(isA<DecodeException>()),
        );
        expect(base.listSync(), isEmpty);
      } finally {
        await scoped.close();
        base.deleteSync(recursive: true);
      }
    });

    test('cancellation before start', () {
      final token = CancellationToken()..cancel();
      expect(
        t.transform(_fixture('landscape.jpg'), const [
          ImageOutput(name: 'a'),
        ], cancel: token),
        throwsA(isA<TransformCancelledException>()),
      );
    });

    test('process timeouts', () async {
      if (kind != BackendKind.cli) return markTestSkipped('CLI only');
      final slow = await ImageTransformer.create(
        const TransformerConfig(
          backend: BackendPreference.cli,
          cli: CliConfig(processTimeout: Duration(microseconds: 1)),
        ),
      );
      try {
        await expectLater(
          slow.transform(_fixture('landscape.jpg'), const [
            ImageOutput(name: 'a'),
          ]),
          throwsA(isA<TransformTimeoutException>()),
        );
      } finally {
        await slow.close();
      }
    });

    test('closed transformers reject calls', () async {
      final closed = await ImageTransformer.create(
        TransformerConfig(backend: backend),
      );
      await closed.close();
      expect(() => closed.probe(_fixture('landscape.jpg')), throwsStateError);
    });

    test('convenience functions', () async {
      final bytes = File('$_fixtures/landscape.jpg').readAsBytesSync();
      final webp = await transformBytes(
        bytes,
        resize: const Resize.fit(width: 40),
      );
      expect((await probeBytes(webp)).format, ImageFormat.webp);
      expect((await probeBytes(webp)).width, 40);
    });
  });

  group('backend selection', () {
    test('missing CLI gives actionable reasons', () {
      if (kind != BackendKind.cli) return;
      expect(
        ImageTransformer.create(
          const TransformerConfig(
            backend: BackendPreference.cli,
            cli: CliConfig(vips: '/nonexistent/vips'),
          ),
        ),
        throwsA(
          isA<BackendUnavailableException>().having(
            (e) => e.reasons.join('\n'),
            'reasons',
            contains('cli:'),
          ),
        ),
      );
    });
  });
}
