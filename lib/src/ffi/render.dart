/// The FFI backend's image work, run synchronously inside a worker isolate.
/// Mirrors the CLI backend step for step (specs/03 §3.1, §3.2), using the
/// same validated option strings.
@internal
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../cli_args.dart';
import '../exceptions.dart';
import '../inputs_outputs.dart';
import '../options.dart';
import '../planning.dart';
import '../types.dart';
import '../vips_text.dart';
import 'vips.dart';

// ignore_for_file: public_member_api_docs

/// An encoded output and its measured size.
final class RenderedImage {
  const RenderedImage(this.bytes, this.width, this.height, this.frames);

  final Uint8List bytes;
  final int width;
  final int height;
  final int frames;
}

/// Reads the header of [source]. Throws [UnsupportedFormatException] if no
/// allowed loader recognises it, and [DecodeException] if the header is
/// unreadable.
Map<String, String> probeSource(VipsBlob source) {
  final loader = findLoader(source);
  if (loader == null) {
    throw const UnsupportedFormatException('Not a supported image');
  }
  try {
    final image = loadHeader(source, loader);
    try {
      return headerFields(image);
    } finally {
      image.dispose();
    }
  } on VipsError catch (e) {
    throw DecodeException(
      'Could not read the image header',
      vipsError: sanitizeVipsError(e.message),
    );
  }
}

String _strip(String bracketed) =>
    bracketed.isEmpty ? '' : bracketed.substring(1, bracketed.length - 1);

String _thumbnailOptions({
  required int width,
  int? height,
  String? size,
  String? crop,
  required TransformOptions options,
}) => [
  'width=$width',
  if (height != null) 'height=$height',
  if (size != null) 'size=$size',
  if (crop != null) 'crop=$crop',
  if (!options.autoOrient) 'no_rotate=true',
  if (options.color == ColorPolicy.srgb) 'export_profile=srgb',
  'fail_on=${options.failOn.name}',
].join(',');

VipsImage _thumbnail(
  VipsBlob source,
  ImageInfo info, {
  required bool allFrames,
  required FailOn failOn,
  required String options,
}) {
  // `thumbnail_buffer` doesn't forward its own `fail_on` to the loader, so
  // it goes in the loader options too.
  final load = [
    _strip(CliArgs.loadOptions(info.format, allFrames: allFrames)),
    'fail_on=${failOn.name}',
  ].where((o) => o.isNotEmpty).join(',');
  try {
    return runOperation(
      'thumbnail_buffer',
      args: {'buffer': source, if (load.isNotEmpty) 'option_string': load},
      options: options,
      read: readImage,
    );
  } on VipsError catch (e) {
    final error = sanitizeVipsError(e.message);
    if (looksLikeDecodeError(e.message)) {
      throw DecodeException('The image could not be decoded', vipsError: error);
    }
    throw EncodeException('libvips failed', vipsError: error);
  }
}

/// Runs a step after the initial resize. libvips decodes lazily, so a
/// broken source can still surface here (e.g. a truncated JPEG during the
/// save), and is reported as a [DecodeException] like in the CLI backend.
T _encodeStep<T>(T Function() step) {
  try {
    return step();
  } on VipsError catch (e) {
    final error = sanitizeVipsError(e.message);
    if (looksLikeDecodeError(e.message)) {
      throw DecodeException('The image could not be decoded', vipsError: error);
    }
    throw EncodeException('libvips failed', vipsError: error);
  }
}

VipsImage _extract(VipsImage image, int left, int top, int width, int height) =>
    _encodeStep(
      () => runOperation(
        'extract_area',
        args: {'input': image},
        options: 'left=$left,top=$top,width=$width,height=$height',
        read: readImage,
      ),
    );

Uint8List _save(
  VipsImage image,
  Encode encode,
  MetadataPolicy metadata, {
  int? pageHeight,
}) => _encodeStep(
  () => runOperation(
    switch (encode.format) {
      ImageFormat.jpeg => 'jpegsave_buffer',
      ImageFormat.png => 'pngsave_buffer',
      ImageFormat.webp => 'webpsave_buffer',
      _ => throw ArgumentError.value(encode, 'encode', 'Unsupported encoder'),
    },
    args: {'in': image},
    options: _strip(
      CliArgs.saveOptions(encode, metadata, pageHeight: pageHeight),
    ),
    read: readBlob,
  ),
);

RenderedImage _measure(Uint8List bytes) {
  final fields = headerOfBytes(bytes);
  if (fields == null) {
    throw const EncodeException('Could not measure the output');
  }
  final info = imageInfoFromHeader(fields);
  return RenderedImage(bytes, info.width, info.height, info.frames);
}

/// Renders one planned output (same steps as `CliArgs.renderStep` plus the
/// CLI backend's manual crops).
RenderedImage renderOutput(
  VipsBlob source,
  ImageInfo info,
  PlannedOutput planned,
  TransformOptions options,
) {
  final encode = planned.output.encode;
  final resize = planned.output.resize;
  final fit = planned.fit;
  final cover = planned.cover;
  final allFrames = planned.loadAllFrames;

  if (cover != null && resize is CoverResize) {
    final manualCrop = resize.crop is FocalCrop || allFrames;
    if (!manualCrop) {
      final image = _thumbnail(
        source,
        info,
        allFrames: allFrames,
        failOn: options.failOn,
        options: _thumbnailOptions(
          width: cover.boxWidth,
          height: cover.boxHeight,
          size: resize.upscale ? 'both' : 'down',
          crop: switch (resize.crop) {
            AttentionCrop() => 'attention',
            EntropyCrop() => 'entropy',
            _ => 'centre',
          },
          options: options,
        ),
      );
      try {
        return _measure(_save(image, encode, options.metadata));
      } finally {
        image.dispose();
      }
    }
    final resized = _thumbnail(
      source,
      info,
      allFrames: allFrames,
      failOn: options.failOn,
      options: _thumbnailOptions(
        width: cover.resizedWidth,
        height: cover.resizedHeight,
        size: 'force',
        options: options,
      ),
    );
    try {
      return _measure(_cropManually(resized, planned, resize, cover, options));
    } finally {
      resized.dispose();
    }
  }

  final String thumbnailOptions;
  if (fit != null && resize is FitResize) {
    thumbnailOptions = _thumbnailOptions(
      width: resize.width ?? CliArgs.unconstrained,
      // `thumbnail` defaults the height to the width.
      height: resize.height ?? CliArgs.unconstrained,
      size: resize.upscale ? 'both' : 'down',
      options: options,
    );
  } else {
    thumbnailOptions = _thumbnailOptions(
      width: planned.plan.width,
      height: planned.plan.height,
      options: options,
    );
  }
  final image = _thumbnail(
    source,
    info,
    allFrames: allFrames,
    failOn: options.failOn,
    options: thumbnailOptions,
  );
  try {
    return _measure(_save(image, encode, options.metadata));
  } finally {
    image.dispose();
  }
}

/// Focal crops, and crops of animated images (frame by frame).
Uint8List _cropManually(
  VipsImage resized,
  PlannedOutput planned,
  CoverResize resize,
  CoverGeometry cover,
  TransformOptions options,
) {
  final crop = resize.crop;
  final (:left, :top) = crop is FocalCrop
      ? cover.focalOrigin(crop.x, crop.y)
      : (
          left: (cover.resizedWidth - cover.boxWidth) ~/ 2,
          top: (cover.resizedHeight - cover.boxHeight) ~/ 2,
        );
  final encode = planned.output.encode;
  final frames = planned.plan.frames;
  if (frames <= 1) {
    final cropped = _extract(
      resized,
      left,
      top,
      cover.boxWidth,
      cover.boxHeight,
    );
    try {
      return _save(cropped, encode, options.metadata);
    } finally {
      cropped.dispose();
    }
  }
  if (cover.resizedHeight == cover.boxHeight) {
    // Only columns are cropped: one extract over the whole frame stack.
    final cropped = _extract(
      resized,
      left,
      0,
      cover.boxWidth,
      cover.boxHeight * frames,
    );
    try {
      return _save(
        cropped,
        encode,
        options.metadata,
        pageHeight: cover.boxHeight,
      );
    } finally {
      cropped.dispose();
    }
  }
  // Rows are cropped inside each frame: extract each frame and rejoin.
  final parts = <VipsImage>[];
  try {
    for (var i = 0; i < frames; i++) {
      parts.add(
        _extract(
          resized,
          left,
          i * cover.resizedHeight + top,
          cover.boxWidth,
          cover.boxHeight,
        ),
      );
    }
    final joined = _encodeStep(
      () => runOperation(
        'arrayjoin',
        args: {'in': parts},
        options: 'across=1',
        read: readImage,
      ),
    );
    try {
      return _save(
        joined,
        encode,
        options.metadata,
        pageHeight: cover.boxHeight,
      );
    } finally {
      joined.dispose();
    }
  } finally {
    for (final part in parts) {
      part.dispose();
    }
  }
}

/// Renders the placeholder (first frame, metadata stripped).
RenderedImage renderPlaceholder(
  VipsBlob source,
  ImageInfo info,
  PlaceholderOptions placeholder,
  TransformOptions options,
) {
  final image = _thumbnail(
    source,
    info,
    allFrames: false,
    failOn: options.failOn,
    options: _thumbnailOptions(
      width: placeholder.size,
      height: placeholder.size,
      size: 'down',
      options: options,
    ),
  );
  try {
    return _measure(_save(image, placeholder.encode, MetadataPolicy.none));
  } finally {
    image.dispose();
  }
}
