import 'package:image_transform/image_transform.dart';
import 'package:image_transform/src/planning.dart';
import 'package:test/test.dart';

ImageInfo _info(
  int width,
  int height, {
  int orientation = 1,
  int frames = 1,
  ImageFormat format = ImageFormat.jpeg,
}) => ImageInfo(
  format: format,
  loader: '${format.name}load',
  width: width,
  height: height,
  orientation: orientation,
  frames: frames,
  hasAlpha: false,
  colorSpace: ColorSpace.srgb,
  hasIccProfile: false,
  byteLength: 1000,
);

void main() {
  group('Geometry.fit', () {
    final cases = <(String, int, int, int?, int?, bool, int, int, bool)>[
      ('width only', 4000, 3000, 640, null, false, 640, 480, false),
      ('height only', 4000, 3000, null, 300, false, 400, 300, false),
      ('box, width binds', 4000, 3000, 1000, 1000, false, 1000, 750, false),
      ('box, height binds', 3000, 4000, 1000, 1000, false, 750, 1000, false),
      ('larger than source', 400, 300, 800, null, false, 400, 300, true),
      ('larger box than source', 400, 300, 800, 800, false, 400, 300, true),
      ('upscale', 400, 300, 800, null, true, 800, 600, false),
      ('exact size', 400, 300, 400, 300, false, 400, 300, false),
      ('1x1 source', 1, 1, 100, 100, false, 1, 1, true),
      ('extreme aspect never 0', 1, 10000, 100, 100, false, 1, 100, false),
      ('wide extreme', 10000, 1, 100, null, false, 100, 1, false),
    ];
    for (final (name, sw, sh, w, h, up, ew, eh, clamped) in cases) {
      test(name, () {
        final g = Geometry.fit(sw, sh, width: w, height: h, upscale: up);
        expect((g.width, g.height, g.clamped), (ew, eh, clamped));
      });
    }
  });

  group('Geometry.cover', () {
    test('fits inside source', () {
      final g = Geometry.cover(4000, 3000, width: 256, height: 256);
      expect((g.boxWidth, g.boxHeight), (256, 256));
      expect((g.resizedWidth, g.resizedHeight), (342, 256));
      expect(g.clamped, isFalse);
    });

    test('portrait box on landscape source', () {
      final g = Geometry.cover(4000, 3000, width: 300, height: 600);
      expect((g.boxWidth, g.boxHeight), (300, 600));
      expect((g.resizedWidth, g.resizedHeight), (800, 600));
    });

    test('clamped keeps aspect ratio at source resolution', () {
      final g = Geometry.cover(400, 300, width: 1000, height: 500);
      expect((g.boxWidth, g.boxHeight, g.clamped), (400, 200, true));
      expect((g.resizedWidth, g.resizedHeight), (400, 300));
    });

    test('upscale fills the requested box', () {
      final g = Geometry.cover(
        400,
        300,
        width: 1000,
        height: 500,
        upscale: true,
      );
      expect((g.boxWidth, g.boxHeight, g.clamped), (1000, 500, false));
      expect((g.resizedWidth, g.resizedHeight), (1000, 750));
    });

    test('resized size always covers the box', () {
      for (final (sw, sh) in [(333, 777), (1001, 999), (7, 3), (4000, 1)]) {
        for (final (w, h) in [(1, 1), (100, 37), (37, 100), (5, 5)]) {
          final g = Geometry.cover(sw, sh, width: w, height: h);
          expect(g.resizedWidth, greaterThanOrEqualTo(g.boxWidth));
          expect(g.resizedHeight, greaterThanOrEqualTo(g.boxHeight));
          expect(g.boxWidth, greaterThanOrEqualTo(1));
          expect(g.boxHeight, greaterThanOrEqualTo(1));
        }
      }
    });

    test('focal origin is clamped to the image', () {
      final g = Geometry.cover(4000, 3000, width: 256, height: 256);
      expect(g.focalOrigin(0, 0), (left: 0, top: 0));
      expect(g.focalOrigin(1, 1), (left: 342 - 256, top: 0));
      expect(g.focalOrigin(0.5, 0.5), (left: 43, top: 0));
      expect(g.focalOrigin(0.25, 0.5), (left: 0, top: 0));
    });
  });

  group('planOutput', () {
    test('all eight orientations use the upright size', () {
      for (var o = 1; o <= 8; o++) {
        final plan = planOutput(
          _info(400, 300, orientation: o),
          const ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
          const TransformOptions(),
        ).plan;
        final expected = o >= 5 ? (100, 133) : (100, 75);
        expect((plan.width, plan.height), expected, reason: 'orientation $o');
      }
    });

    test('autoOrient: false uses the stored size', () {
      final plan = planOutput(
        _info(400, 300, orientation: 6),
        const ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
        const TransformOptions(autoOrient: false),
      ).plan;
      expect((plan.width, plan.height), (100, 75));
    });

    test('no resize keeps the upright size', () {
      final plan = planOutput(
        _info(400, 300, orientation: 8),
        const ImageOutput(name: 'a'),
        const TransformOptions(),
      ).plan;
      expect((plan.width, plan.height, plan.clamped), (300, 400, false));
    });

    group('animation', () {
      final gif = _info(200, 100, frames: 4, format: ImageFormat.gif);
      int frames(
        ImageOutput output, [
        TransformOptions options = const TransformOptions(),
      ]) => planOutput(gif, output, options).plan.frames;

      test('WebP keeps frames', () {
        expect(
          frames(const ImageOutput(name: 'a', resize: Resize.fit(width: 50))),
          4,
        );
        expect(
          frames(const ImageOutput(name: 'a', resize: Resize.cover(50, 50))),
          4,
        );
      });
      test('JPEG and PNG are stills', () {
        expect(frames(const ImageOutput(name: 'a', encode: Encode.jpeg())), 1);
        expect(frames(const ImageOutput(name: 'a', encode: Encode.png())), 1);
      });
      test('firstFrame is a still', () {
        expect(
          frames(
            const ImageOutput(name: 'a'),
            const TransformOptions(animation: AnimationMode.firstFrame),
          ),
          1,
        );
      });
      test('focal crop uses the first frame', () {
        expect(
          frames(
            const ImageOutput(
              name: 'a',
              resize: Resize.cover(50, 50, crop: Crop.focal(0.2, 0.2)),
            ),
          ),
          1,
        );
      });
    });

    test('encoder dimension limits', () {
      expect(
        () => planOutput(
          _info(20000, 100),
          const ImageOutput(name: 'a', resize: Resize.fit(width: 20000)),
          const TransformOptions(),
        ),
        throwsA(
          isA<InvalidTransformException>().having(
            (e) => e.field,
            'field',
            'outputs[0].resize',
          ),
        ),
      );
      expect(
        planOutput(
          _info(20000, 100),
          const ImageOutput(
            name: 'a',
            resize: Resize.fit(width: 20000),
            encode: Encode.jpeg(),
          ),
          const TransformOptions(),
        ).plan.width,
        20000,
      );
    });
  });
}
