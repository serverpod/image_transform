import 'package:meta/meta.dart';

import 'exceptions.dart';
import 'inputs_outputs.dart';
import 'options.dart';
import 'types.dart';

/// Predicted result of one output, computed without running libvips.
final class OutputPlan {
  /// Creates a plan.
  const OutputPlan({
    required this.width,
    required this.height,
    required this.frames,
    required this.clamped,
  });

  /// Predicted output width.
  final int width;

  /// Predicted output height (of one frame).
  final int height;

  /// Predicted frame count.
  final int frames;

  /// Whether the requested size exceeded the source and was clamped.
  final bool clamped;
}

/// Result of fit geometry.
@internal
final class FitGeometry {
  const FitGeometry(this.width, this.height, {required this.clamped});
  final int width;
  final int height;
  final bool clamped;
}

/// Result of cover geometry.
@internal
final class CoverGeometry {
  const CoverGeometry({
    required this.boxWidth,
    required this.boxHeight,
    required this.resizedWidth,
    required this.resizedHeight,
    required this.clamped,
  });

  final int boxWidth;
  final int boxHeight;
  final int resizedWidth;
  final int resizedHeight;
  final bool clamped;

  /// Crop window origin for a focal point (fractions of the upright image).
  ({int left, int top}) focalOrigin(double fx, double fy) => (
    left: (fx * resizedWidth - boxWidth / 2).round().clamp(
      0,
      resizedWidth - boxWidth,
    ),
    top: (fy * resizedHeight - boxHeight / 2).round().clamp(
      0,
      resizedHeight - boxHeight,
    ),
  );
}

/// Pure resize geometry (spec 02 §2.4). All sizes are of the upright image.
@internal
abstract final class Geometry {
  static const _epsilon = 1e-9;

  /// Fit inside [width] × [height] (at least one given).
  static FitGeometry fit(
    int sw,
    int sh, {
    int? width,
    int? height,
    bool upscale = false,
  }) {
    final ratios = [
      if (width != null) width / sw,
      if (height != null) height / sh,
    ];
    final unclamped = ratios.reduce((a, b) => a < b ? a : b);
    final scale = upscale ? unclamped : (unclamped < 1 ? unclamped : 1.0);
    return FitGeometry(
      _atLeastOne((sw * scale).round()),
      _atLeastOne((sh * scale).round()),
      clamped: !upscale && unclamped > 1 + _epsilon,
    );
  }

  /// Fill [width] × [height], cropping the overflow.
  static CoverGeometry cover(
    int sw,
    int sh, {
    required int width,
    required int height,
    bool upscale = false,
  }) {
    var boxW = width;
    var boxH = height;
    var clamped = false;
    if (!upscale && (width > sw || height > sh)) {
      final k = _min(sw / width, sh / height);
      boxW = _atLeastOne((width * k + _epsilon).floor());
      boxH = _atLeastOne((height * k + _epsilon).floor());
      clamped = true;
    }
    final s = _max(boxW / sw, boxH / sh);
    return CoverGeometry(
      boxWidth: boxW,
      boxHeight: boxH,
      resizedWidth: _max((sw * s - _epsilon).ceil(), boxW),
      resizedHeight: _max((sh * s - _epsilon).ceil(), boxH),
      clamped: clamped,
    );
  }

  static int _atLeastOne(int v) => v < 1 ? 1 : v;
  static T _min<T extends num>(T a, T b) => a < b ? a : b;
  static T _max<T extends num>(T a, T b) => a > b ? a : b;
}

/// An output with its validated, computed geometry. Backends execute these.
@internal
final class PlannedOutput {
  const PlannedOutput({
    required this.index,
    required this.output,
    required this.plan,
    required this.loadAllFrames,
    this.fit,
    this.cover,
  });

  /// Position in the request (used for temp file names).
  final int index;
  final ImageOutput output;
  final OutputPlan plan;

  /// Whether all frames are loaded (animated WebP output).
  final bool loadAllFrames;
  final FitGeometry? fit;
  final CoverGeometry? cover;
}

/// Largest dimension each encoder accepts.
const _maxDimension = {
  ImageFormat.webp: 16383,
  ImageFormat.jpeg: 65500,
  ImageFormat.png: 10000000,
};

/// Plans one output against [source]. Throws [InvalidTransformException].
@internal
PlannedOutput planOutput(
  ImageInfo source,
  ImageOutput output,
  TransformOptions options, {
  int index = 0,
}) {
  validateOutput(output, 'outputs[$index]');
  final sw = options.autoOrient ? source.orientedWidth : source.width;
  final sh = options.autoOrient ? source.orientedHeight : source.height;
  final resize = output.resize;
  final canAnimate =
      source.isAnimated &&
      options.animation == AnimationMode.preserve &&
      output.encode is WebpEncode &&
      !(resize is CoverResize && resize.crop is FocalCrop);

  FitGeometry? fit;
  CoverGeometry? cover;
  switch (resize) {
    case null:
      break;
    case FitResize():
      fit = Geometry.fit(
        sw,
        sh,
        width: resize.width,
        height: resize.height,
        upscale: resize.upscale,
      );
    case CoverResize():
      cover = Geometry.cover(
        sw,
        sh,
        width: resize.width,
        height: resize.height,
        upscale: resize.upscale,
      );
    default:
      throw InvalidTransformException(
        'Unsupported resize ${resize.runtimeType}',
        field: 'outputs[$index].resize',
      );
  }
  final (width, height, clamped) = fit != null
      ? (fit.width, fit.height, fit.clamped)
      : cover != null
      ? (cover.boxWidth, cover.boxHeight, cover.clamped)
      : (sw, sh, false);

  final max = _maxDimension[output.encode.format]!;
  if (width > max || height > max) {
    throw InvalidTransformException(
      '${output.encode.format.name} outputs are limited to ${max}px per side '
      '(planned ${width}x$height)',
      field: 'outputs[$index].resize',
    );
  }
  return PlannedOutput(
    index: index,
    output: output,
    loadAllFrames: canAnimate,
    fit: fit,
    cover: cover,
    plan: OutputPlan(
      width: width,
      height: height,
      frames: canAnimate ? source.frames : 1,
      clamped: clamped,
    ),
  );
}

/// Validates an output's parameters. Throws [InvalidTransformException].
@internal
void validateOutput(ImageOutput output, String field) {
  if (output.name.isEmpty) {
    throw InvalidTransformException(
      'Output name is empty',
      field: '$field.name',
    );
  }
  void dimension(int? v, String name) {
    if (v != null && v < 1) {
      throw InvalidTransformException(
        '$name must be at least 1',
        field: '$field.resize.$name',
      );
    }
  }

  switch (output.resize) {
    case null:
      break;
    case FitResize(:final width, :final height):
      if (width == null && height == null) {
        throw InvalidTransformException(
          'Fit needs a width and/or a height',
          field: '$field.resize',
        );
      }
      dimension(width, 'width');
      dimension(height, 'height');
    case CoverResize(:final width, :final height, :final crop):
      dimension(width, 'width');
      dimension(height, 'height');
      if (crop is FocalCrop &&
          !(crop.x >= 0 && crop.x <= 1 && crop.y >= 0 && crop.y <= 1)) {
        throw InvalidTransformException(
          'Focal point must be within 0..1',
          field: '$field.resize.crop',
        );
      }
  }
  _validateEncode(output.encode, '$field.encode');
}

void _validateEncode(Encode encode, String field) {
  void range(int v, int min, int max, String name) {
    if (v < min || v > max) {
      throw InvalidTransformException(
        '$name must be within $min..$max (got $v)',
        field: '$field.$name',
      );
    }
  }

  switch (encode) {
    case WebpEncode(:final quality, :final effort, :final alphaQuality):
      range(quality, 1, 100, 'quality');
      range(effort, 0, 6, 'effort');
      range(alphaQuality, 0, 100, 'alphaQuality');
    case JpegEncode(:final quality):
      range(quality, 1, 100, 'quality');
    case PngEncode(:final compression, :final colors):
      range(compression, 0, 9, 'compression');
      range(colors, 2, 256, 'colors');
    default:
      throw InvalidTransformException(
        'Unsupported encoder ${encode.runtimeType}',
        field: field,
      );
  }
}

/// Validates a whole request. Throws [InvalidTransformException].
@internal
void validateRequest(
  List<ImageOutput> outputs,
  PlaceholderOptions? placeholder,
) {
  final names = <String>{};
  for (var i = 0; i < outputs.length; i++) {
    validateOutput(outputs[i], 'outputs[$i]');
    if (!names.add(outputs[i].name)) {
      throw InvalidTransformException(
        'Duplicate output name "${outputs[i].name}"',
        field: 'outputs[$i].name',
      );
    }
  }
  if (placeholder != null) {
    if (placeholder.size < 8 || placeholder.size > 64) {
      throw InvalidTransformException(
        'Placeholder size must be within 8..64 (got ${placeholder.size})',
        field: 'placeholder.size',
      );
    }
    _validateEncode(placeholder.encode, 'placeholder.encode');
  }
}

/// Checks [info] against the allow-list and [limits] (spec 02 §2.3).
@internal
void checkSource(
  ImageInfo info,
  Set<ImageFormat> allowedFormats,
  SourceLimits limits,
  TransformOptions options,
) {
  if (info.format == ImageFormat.other ||
      !allowedFormats.contains(info.format)) {
    throw UnsupportedFormatException(
      'Unsupported input format (${info.loader})',
      detectedLoader: info.loader,
    );
  }
  void check(String limit, int actual, int? max) {
    if (max != null && actual > max) {
      throw SourceLimitsException(
        '$limit exceeded: $actual > $max',
        limit: limit,
        actual: actual,
        max: max,
      );
    }
  }

  final bytes = info.byteLength;
  if (bytes != null) check('maxInputBytes', bytes, limits.maxInputBytes);
  final pixels = info.width * info.height;
  check('maxPixels', pixels, limits.maxPixels);
  if (info.isAnimated && options.animation == AnimationMode.preserve) {
    check('maxFrames', info.frames, limits.maxFrames);
    check('maxAnimatedPixels', pixels * info.frames, limits.maxAnimatedPixels);
  }
}
