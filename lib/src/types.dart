import 'dart:convert';
import 'dart:typed_data';

/// Image formats known to the library.
enum ImageFormat {
  /// JPEG.
  jpeg('image/jpeg', 'jpg'),

  /// PNG.
  png('image/png', 'png'),

  /// WebP (still or animated).
  webp('image/webp', 'webp'),

  /// GIF (still or animated). Decode only.
  gif('image/gif', 'gif'),

  /// Any other format libvips recognised. Never accepted as input by default.
  other('application/octet-stream', 'bin');

  const ImageFormat(this.mimeType, this.extension);

  /// MIME type, e.g. `image/webp`.
  final String mimeType;

  /// Conventional file extension without the dot.
  final String extension;
}

/// Colour space of a decoded image, as reported by libvips.
enum ColorSpace {
  /// 8-bit sRGB.
  srgb,

  /// 16-bit RGB.
  rgb16,

  /// 8-bit greyscale.
  grey,

  /// 16-bit greyscale.
  grey16,

  /// CMYK.
  cmyk,

  /// CIE Lab.
  lab,

  /// Anything else.
  other,
}

/// What happens to animated (multi-frame) inputs.
enum AnimationMode {
  /// Keep all frames when the output format can animate (WebP).
  preserve,

  /// Always output a still image of the first frame.
  firstFrame,
}

/// Colour handling.
enum ColorPolicy {
  /// Convert to sRGB, honouring embedded profiles.
  srgb,

  /// Keep the colour space and embedded profile as they are.
  preserve,
}

/// Which metadata survives in outputs.
enum MetadataPolicy {
  /// Strip everything: EXIF (including GPS), XMP, IPTC and ICC.
  none,

  /// Keep only the ICC profile.
  icc,

  /// Keep everything (the orientation tag is reset when auto-orienting).
  all,
}

/// How strict the decoder is about damaged input.
enum FailOn {
  /// Fail on decode errors such as truncated files (default).
  error,

  /// Also fail on decoder warnings.
  warning,

  /// Render whatever can be decoded.
  none,
}

/// Which backend [TransformerConfig.backend] asks for.
enum BackendPreference {
  /// FFI when available, otherwise the CLI.
  auto,

  /// In-process libvips through `dart:ffi`.
  ffi,

  /// libvips command-line tools in child processes.
  cli,
}

/// The backend a transformer actually uses.
enum BackendKind {
  /// In-process libvips through `dart:ffi`.
  ffi,

  /// libvips command-line tools in child processes.
  cli,
}

/// JPEG chroma subsampling.
enum ChromaSubsampling {
  /// 4:2:0 below quality 90, otherwise 4:4:4 (libvips default).
  auto,

  /// Always 4:2:0.
  yuv420,

  /// Always 4:4:4 (no subsampling).
  yuv444,
}

/// Information about the backend a transformer uses.
final class BackendInfo {
  /// Creates backend information.
  const BackendInfo({
    required this.kind,
    required this.vipsVersion,
    this.reasons = const [],
  });

  /// The backend in use.
  final BackendKind kind;

  /// libvips version, e.g. `8.17.2`.
  final String vipsVersion;

  /// Why this backend was chosen (one entry per selection step).
  final List<String> reasons;

  @override
  String toString() => 'BackendInfo(${kind.name}, libvips $vipsVersion)';
}

/// Header information about a source image. Reading it never decodes pixels.
final class ImageInfo {
  /// Creates image information.
  const ImageInfo({
    required this.format,
    required this.loader,
    required this.width,
    required this.height,
    required this.orientation,
    required this.frames,
    required this.hasAlpha,
    required this.colorSpace,
    required this.hasIccProfile,
    this.byteLength,
  });

  /// Detected format (from content, never from a file extension).
  final ImageFormat format;

  /// libvips loader nickname, e.g. `jpegload`.
  final String loader;

  /// Stored width in pixels.
  final int width;

  /// Stored height in pixels of one frame.
  final int height;

  /// EXIF orientation, 1–8 (1 when absent).
  final int orientation;

  /// Number of frames (1 for still images).
  final int frames;

  /// Whether the image has an alpha channel.
  final bool hasAlpha;

  /// Colour space.
  final ColorSpace colorSpace;

  /// Whether an ICC profile is embedded.
  final bool hasIccProfile;

  /// Size of the encoded source in bytes, when known.
  final int? byteLength;

  /// Whether width and height swap when the orientation is applied.
  bool get orientationSwapsAxes => orientation >= 5 && orientation <= 8;

  /// Width after applying the EXIF orientation.
  int get orientedWidth => orientationSwapsAxes ? height : width;

  /// Height after applying the EXIF orientation.
  int get orientedHeight => orientationSwapsAxes ? width : height;

  /// Whether the image has more than one frame.
  bool get isAnimated => frames > 1;

  @override
  String toString() =>
      'ImageInfo(${format.name} ${width}x$height, frames: $frames, '
      'orientation: $orientation, alpha: $hasAlpha, ${colorSpace.name})';
}

/// A tiny preview image.
final class Placeholder {
  /// Creates a placeholder.
  const Placeholder({
    required this.bytes,
    required this.width,
    required this.height,
    required this.format,
  });

  /// Encoded placeholder bytes.
  final Uint8List bytes;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Encoding format.
  final ImageFormat format;

  /// The placeholder as a `data:` URI, e.g. `data:image/webp;base64,…`.
  String get dataUri => 'data:${format.mimeType};base64,${base64Encode(bytes)}';
}
