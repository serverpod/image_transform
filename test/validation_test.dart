import 'package:image_transform/image_transform.dart';
import 'package:image_transform/src/planning.dart';
import 'package:test/test.dart';

Matcher _invalid(String field) => throwsA(
  isA<InvalidTransformException>().having((e) => e.field, 'field', field),
);

ImageInfo _info({
  int width = 400,
  int height = 300,
  int frames = 1,
  ImageFormat format = ImageFormat.jpeg,
  int bytes = 1000,
}) => ImageInfo(
  format: format,
  loader: format == ImageFormat.other ? 'svgload' : '${format.name}load',
  width: width,
  height: height,
  orientation: 1,
  frames: frames,
  hasAlpha: false,
  colorSpace: ColorSpace.srgb,
  hasIccProfile: false,
  byteLength: bytes,
);

const _allowed = {
  ImageFormat.jpeg,
  ImageFormat.png,
  ImageFormat.webp,
  ImageFormat.gif,
};

void main() {
  group('validateRequest', () {
    test('accepts a typical request', () {
      validateRequest(const [
        ImageOutput(name: 'a', resize: Resize.fit(width: 100)),
        ImageOutput(
          name: 'b',
          resize: Resize.cover(10, 10, crop: Crop.focal(0, 1)),
          encode: Encode.jpeg(),
        ),
        ImageOutput(name: 'c', encode: Encode.png(palette: true, colors: 16)),
      ], const PlaceholderOptions());
    });

    test('rejects bad parameters with the offending field', () {
      expect(
        () => validateRequest(const [ImageOutput(name: '')], null),
        _invalid('outputs[0].name'),
      );
      expect(
        () => validateRequest(const [
          ImageOutput(name: 'a'),
          ImageOutput(name: 'a'),
        ], null),
        _invalid('outputs[1].name'),
      );
      expect(
        () => validateRequest(const [
          ImageOutput(name: 'a', resize: Resize.fit()),
        ], null),
        _invalid('outputs[0].resize'),
      );
      expect(
        () => validateRequest(const [
          ImageOutput(name: 'a', resize: Resize.fit(width: 0)),
        ], null),
        _invalid('outputs[0].resize.width'),
      );
      expect(
        () => validateRequest(const [
          ImageOutput(name: 'a', resize: Resize.cover(10, 0)),
        ], null),
        _invalid('outputs[0].resize.height'),
      );
      expect(
        () => validateRequest(const [
          ImageOutput(
            name: 'a',
            resize: Resize.cover(10, 10, crop: Crop.focal(1.5, 0)),
          ),
        ], null),
        _invalid('outputs[0].resize.crop'),
      );
      expect(
        () => validateRequest(const [
          ImageOutput(name: 'a', encode: Encode.webp(quality: 0)),
        ], null),
        _invalid('outputs[0].encode.quality'),
      );
      expect(
        () => validateRequest(const [
          ImageOutput(name: 'a', encode: Encode.webp(effort: 7)),
        ], null),
        _invalid('outputs[0].encode.effort'),
      );
      expect(
        () => validateRequest(const [
          ImageOutput(name: 'a', encode: Encode.jpeg(quality: 101)),
        ], null),
        _invalid('outputs[0].encode.quality'),
      );
      expect(
        () => validateRequest(const [
          ImageOutput(name: 'a', encode: Encode.png(compression: 10)),
        ], null),
        _invalid('outputs[0].encode.compression'),
      );
      expect(
        () => validateRequest(const [], const PlaceholderOptions(size: 4)),
        _invalid('placeholder.size'),
      );
    });
  });

  group('checkSource', () {
    test('accepts allowed formats within limits', () {
      checkSource(
        _info(),
        _allowed,
        SourceLimits.defaults,
        const TransformOptions(),
      );
    });

    test('rejects other and disallowed formats', () {
      expect(
        () => checkSource(
          _info(format: ImageFormat.other),
          _allowed,
          SourceLimits.defaults,
          const TransformOptions(),
        ),
        throwsA(
          isA<UnsupportedFormatException>().having(
            (e) => e.detectedLoader,
            'loader',
            'svgload',
          ),
        ),
      );
      expect(
        () => checkSource(
          _info(format: ImageFormat.gif),
          {ImageFormat.jpeg},
          SourceLimits.defaults,
          const TransformOptions(),
        ),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });

    Matcher limit(String name) => throwsA(
      isA<SourceLimitsException>().having((e) => e.limit, 'limit', name),
    );

    test('enforces limits', () {
      const limits = SourceLimits(
        maxInputBytes: 500,
        maxPixels: 1000,
        maxFrames: 3,
        maxAnimatedPixels: 2000,
      );
      const options = TransformOptions();
      expect(
        () => checkSource(
          _info(width: 10, height: 10),
          _allowed,
          limits,
          options,
        ),
        limit('maxInputBytes'),
      );
      expect(
        () => checkSource(
          _info(width: 100, height: 100, bytes: 1),
          _allowed,
          limits,
          options,
        ),
        limit('maxPixels'),
      );
      expect(
        () => checkSource(
          _info(width: 10, height: 10, frames: 4, bytes: 1),
          _allowed,
          limits,
          options,
        ),
        limit('maxFrames'),
      );
      expect(
        () => checkSource(
          _info(width: 30, height: 30, frames: 3, bytes: 1),
          _allowed,
          limits,
          options,
        ),
        limit('maxAnimatedPixels'),
      );
    });

    test('frame limits only apply when animation is preserved', () {
      const limits = SourceLimits(maxFrames: 3, maxAnimatedPixels: 10);
      checkSource(
        _info(width: 10, height: 10, frames: 100),
        _allowed,
        limits,
        const TransformOptions(animation: AnimationMode.firstFrame),
      );
    });

    test('unlimited accepts anything', () {
      checkSource(
        _info(width: 100000, height: 100000, frames: 5000),
        _allowed,
        SourceLimits.unlimited,
        const TransformOptions(),
      );
    });
  });
}
