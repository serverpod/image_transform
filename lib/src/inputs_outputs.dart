import 'dart:typed_data';

import 'types.dart';

/// Where a source image comes from. The format is always detected from the
/// content, never from a file extension.
abstract base class ImageInput {
  const ImageInput._();

  /// An image file on disk.
  const factory ImageInput.file(String path) = FileInput;

  /// An image held in memory.
  const factory ImageInput.bytes(Uint8List bytes) = BytesInput;

  /// An image read from a stream. It's spooled (to a temp file for the CLI
  /// backend) and aborted as soon as `SourceLimits.maxInputBytes` is exceeded.
  factory ImageInput.stream(Stream<List<int>> stream, {int? length}) =
      StreamInput;
}

/// An image file on disk.
final class FileInput extends ImageInput {
  /// Creates a file input.
  const FileInput(this.path) : super._();

  /// Path to the file.
  final String path;
}

/// An image held in memory.
final class BytesInput extends ImageInput {
  /// Creates a bytes input.
  const BytesInput(this.bytes) : super._();

  /// Encoded image bytes.
  final Uint8List bytes;
}

/// An image read from a stream. Can be consumed once.
final class StreamInput extends ImageInput {
  /// Creates a stream input. [length] is the expected byte length, if known.
  StreamInput(this.stream, {this.length}) : super._();

  /// The byte stream.
  final Stream<List<int>> stream;

  /// Expected length in bytes, if known.
  final int? length;
}

/// One output to produce from the source.
final class ImageOutput {
  /// Creates an output description.
  const ImageOutput({
    required this.name,
    this.resize,
    this.encode = const Encode.webp(),
    this.to = const OutputTarget.bytes(),
  });

  /// Unique name within one call; used to look up the result.
  final String name;

  /// How to resize. `null` keeps the (oriented) source dimensions.
  final Resize? resize;

  /// How to encode.
  final Encode encode;

  /// Where the encoded output goes.
  final OutputTarget to;
}

/// How to resize an image.
abstract base class Resize {
  const Resize._({required this.upscale});

  /// Fits inside [width] × [height] (either may be omitted), keeping the
  /// aspect ratio. Never enlarges unless [upscale] is true.
  const factory Resize.fit({int? width, int? height, bool upscale}) = FitResize;

  /// Fills exactly [width] × [height], cropping the overflow with [crop].
  /// Never enlarges unless [upscale] is true; a too-small source yields the
  /// largest box with the requested aspect ratio that fits inside it.
  const factory Resize.cover(int width, int height, {Crop crop, bool upscale}) =
      CoverResize;

  /// Whether the image may be enlarged.
  final bool upscale;
}

/// Fit inside a box, keeping the aspect ratio.
final class FitResize extends Resize {
  /// Creates a fit resize.
  const FitResize({this.width, this.height, super.upscale = false}) : super._();

  /// Maximum width, if constrained.
  final int? width;

  /// Maximum height, if constrained.
  final int? height;
}

/// Fill a box exactly, cropping the overflow.
final class CoverResize extends Resize {
  /// Creates a cover resize.
  const CoverResize(
    this.width,
    this.height, {
    this.crop = const Crop.centre(),
    super.upscale = false,
  }) : super._();

  /// Target width.
  final int width;

  /// Target height.
  final int height;

  /// How to choose the visible region.
  final Crop crop;
}

/// How [CoverResize] chooses the region to keep.
abstract base class Crop {
  const Crop._();

  /// Keep the centre.
  const factory Crop.centre() = CentreCrop;

  /// Keep the most salient region (faces, objects, skin tones, colour).
  const factory Crop.attention() = AttentionCrop;

  /// Keep the most detailed region.
  const factory Crop.entropy() = EntropyCrop;

  /// Keep the region around a focal point; [x] and [y] are 0..1 relative to
  /// the upright image.
  const factory Crop.focal(double x, double y) = FocalCrop;
}

/// Keep the centre.
final class CentreCrop extends Crop {
  /// Creates a centre crop.
  const CentreCrop() : super._();
}

/// Keep the most salient region.
final class AttentionCrop extends Crop {
  /// Creates an attention crop.
  const AttentionCrop() : super._();
}

/// Keep the most detailed region.
final class EntropyCrop extends Crop {
  /// Creates an entropy crop.
  const EntropyCrop() : super._();
}

/// Keep the region around a focal point.
final class FocalCrop extends Crop {
  /// Creates a focal crop.
  const FocalCrop(this.x, this.y) : super._();

  /// Horizontal focal position, 0 (left) to 1 (right).
  final double x;

  /// Vertical focal position, 0 (top) to 1 (bottom).
  final double y;
}

/// How to encode an output.
abstract base class Encode {
  const Encode._();

  /// WebP. Animated sources stay animated unless `AnimationMode.firstFrame`.
  const factory Encode.webp({
    int quality,
    bool lossless,
    int effort,
    bool smartSubsample,
    int alphaQuality,
  }) = WebpEncode;

  /// JPEG. Alpha is flattened onto white.
  const factory Encode.jpeg({
    int quality,
    bool progressive,
    bool optimizeCoding,
    ChromaSubsampling subsampling,
  }) = JpegEncode;

  /// PNG.
  const factory Encode.png({int compression, bool palette, int colors}) =
      PngEncode;

  /// The output format.
  ImageFormat get format;
}

/// WebP encoding options.
final class WebpEncode extends Encode {
  /// Creates WebP options.
  const WebpEncode({
    this.quality = 80,
    this.lossless = false,
    this.effort = 4,
    this.smartSubsample = true,
    this.alphaQuality = 100,
  }) : super._();

  /// Quality 1–100 (ignored when [lossless]).
  final int quality;

  /// Lossless compression.
  final bool lossless;

  /// CPU effort 0–6; higher is smaller and slower.
  final int effort;

  /// Sharper colour edges for lossy output.
  final bool smartSubsample;

  /// Alpha quality 0–100.
  final int alphaQuality;

  @override
  ImageFormat get format => ImageFormat.webp;
}

/// JPEG encoding options.
final class JpegEncode extends Encode {
  /// Creates JPEG options.
  const JpegEncode({
    this.quality = 82,
    this.progressive = true,
    this.optimizeCoding = true,
    this.subsampling = ChromaSubsampling.auto,
  }) : super._();

  /// Quality 1–100.
  final int quality;

  /// Progressive (interlaced) JPEG.
  final bool progressive;

  /// Optimise Huffman tables.
  final bool optimizeCoding;

  /// Chroma subsampling.
  final ChromaSubsampling subsampling;

  @override
  ImageFormat get format => ImageFormat.jpeg;
}

/// PNG encoding options.
final class PngEncode extends Encode {
  /// Creates PNG options.
  const PngEncode({
    this.compression = 6,
    this.palette = false,
    this.colors = 256,
  }) : super._();

  /// zlib compression level 0–9.
  final int compression;

  /// Quantise to a palette (requires a quantiser in the libvips build).
  final bool palette;

  /// Maximum palette size, 2–256 (only with [palette]).
  final int colors;

  @override
  ImageFormat get format => ImageFormat.png;
}

/// Where an encoded output goes.
abstract base class OutputTarget {
  const OutputTarget._();

  /// Return the encoded bytes in the result.
  const factory OutputTarget.bytes() = BytesTarget;

  /// Write to [path] atomically (temp file + rename). Parent directories are
  /// created as needed.
  const factory OutputTarget.file(String path) = FileTarget;
}

/// Return the encoded bytes in the result.
final class BytesTarget extends OutputTarget {
  /// Creates a bytes target.
  const BytesTarget() : super._();
}

/// Write the encoded output to a file.
final class FileTarget extends OutputTarget {
  /// Creates a file target.
  const FileTarget(this.path) : super._();

  /// Destination path.
  final String path;
}
