import 'inputs_outputs.dart';
import 'types.dart';

/// Upper bounds checked from the image header, before any pixels are decoded.
/// A `null` field means "no limit".
final class SourceLimits {
  /// Creates limits.
  const SourceLimits({
    this.maxInputBytes,
    this.maxPixels,
    this.maxFrames,
    this.maxAnimatedPixels,
  });

  /// Defaults suitable for untrusted input.
  static const defaults = SourceLimits(
    maxInputBytes: 256 * 1024 * 1024,
    maxPixels: 268402689, // 16383², like sharp's limitInputPixels
    maxFrames: 1000,
    maxAnimatedPixels: 1000000000,
  );

  /// No limits at all.
  static const unlimited = SourceLimits();

  /// Maximum encoded input size in bytes.
  final int? maxInputBytes;

  /// Maximum `width × height` of one frame.
  final int? maxPixels;

  /// Maximum frame count (only checked when animation is preserved).
  final int? maxFrames;

  /// Maximum `width × height × frames` (only checked when animation is
  /// preserved).
  final int? maxAnimatedPixels;
}

/// Per-call processing options.
final class TransformOptions {
  /// Creates options.
  const TransformOptions({
    this.animation = AnimationMode.preserve,
    this.autoOrient = true,
    this.color = ColorPolicy.srgb,
    this.metadata = MetadataPolicy.none,
    this.failOn = FailOn.error,
    this.limits,
  });

  /// Whether animated inputs stay animated.
  final AnimationMode animation;

  /// Rotate pixels upright according to the EXIF orientation.
  final bool autoOrient;

  /// Colour handling.
  final ColorPolicy color;

  /// Which metadata is kept.
  final MetadataPolicy metadata;

  /// Decoder strictness.
  final FailOn failOn;

  /// Overrides `TransformerConfig.limits` for this call.
  final SourceLimits? limits;
}

/// Options for the tiny placeholder produced alongside the outputs.
final class PlaceholderOptions {
  /// Creates placeholder options.
  const PlaceholderOptions({
    this.size = 24,
    this.encode = const Encode.webp(quality: 50, effort: 6),
  });

  /// Longest edge in pixels, 8–64.
  final int size;

  /// Encoding of the placeholder.
  final Encode encode;
}

/// Settings of the CLI backend.
final class CliConfig {
  /// Creates CLI settings.
  const CliConfig({
    this.vips = 'vips',
    this.vipsheader = 'vipsheader',
    this.processTimeout = const Duration(seconds: 60),
    this.environment = const {},
  });

  /// Path or name of the `vips` executable.
  final String vips;

  /// Path or name of the `vipsheader` executable.
  final String vipsheader;

  /// Each libvips process is killed after this long.
  final Duration processTimeout;

  /// Extra environment variables for libvips processes.
  final Map<String, String> environment;
}

/// Settings of an `ImageTransformer`.
final class TransformerConfig {
  /// Creates a configuration.
  const TransformerConfig({
    this.backend = BackendPreference.auto,
    this.workers,
    this.vipsThreads,
    this.allowedFormats = const {
      ImageFormat.jpeg,
      ImageFormat.png,
      ImageFormat.webp,
      ImageFormat.gif,
    },
    this.limits = SourceLimits.defaults,
    this.tempDirectory,
    this.cli = const CliConfig(),
  });

  /// Which backend to use.
  final BackendPreference backend;

  /// Maximum parallel libvips operations. Defaults to half the CPU cores
  /// (at least 1).
  final int? workers;

  /// libvips threads per operation. Defaults to the libvips default.
  final int? vipsThreads;

  /// Input formats that are accepted.
  final Set<ImageFormat> allowedFormats;

  /// Default source limits.
  final SourceLimits limits;

  /// Directory for temporary files (path). Defaults to the system temp dir.
  final String? tempDirectory;

  /// CLI backend settings.
  final CliConfig cli;
}
