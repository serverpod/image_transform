/// Base class of every error thrown or reported by `image_transform`.
abstract base class ImageTransformException implements Exception {
  /// Creates an exception with a human-readable [message].
  const ImageTransformException(this.message);

  /// Human-readable description. Never contains file paths.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The input isn't an image, or its format isn't allowed.
final class UnsupportedFormatException extends ImageTransformException {
  /// Creates the exception.
  const UnsupportedFormatException(super.message, {this.detectedLoader});

  /// The libvips loader that recognised the input, if any.
  final String? detectedLoader;
}

/// The input exceeds one of the configured `SourceLimits`.
final class SourceLimitsException extends ImageTransformException {
  /// Creates the exception.
  const SourceLimitsException(
    super.message, {
    required this.limit,
    required this.actual,
    required this.max,
  });

  /// Name of the exceeded limit, e.g. `maxPixels`.
  final String limit;

  /// The value found in the input.
  final int actual;

  /// The configured maximum.
  final int max;
}

/// The input couldn't be decoded (corrupt or truncated).
final class DecodeException extends ImageTransformException {
  /// Creates the exception.
  const DecodeException(super.message, {this.vipsError = ''});

  /// Sanitised libvips error output.
  final String vipsError;
}

/// An output couldn't be encoded or written.
final class EncodeException extends ImageTransformException {
  /// Creates the exception.
  const EncodeException(super.message, {this.vipsError = ''});

  /// Sanitised libvips error output.
  final String vipsError;
}

/// A transform parameter is invalid.
final class InvalidTransformException extends ImageTransformException {
  /// Creates the exception.
  const InvalidTransformException(super.message, {required this.field});

  /// The offending field, e.g. `outputs[2].resize.width`.
  final String field;
}

/// A libvips process exceeded its time limit (CLI backend).
final class TransformTimeoutException extends ImageTransformException {
  /// Creates the exception.
  const TransformTimeoutException(super.message);
}

/// The operation was cancelled through a `CancellationToken`.
final class TransformCancelledException extends ImageTransformException {
  /// Creates the exception.
  const TransformCancelledException([super.message = 'Cancelled']);
}

/// No usable backend was found.
final class BackendUnavailableException extends ImageTransformException {
  /// Creates the exception.
  const BackendUnavailableException(super.message, {this.reasons = const []});

  /// One reason per attempted backend, with a hint on how to fix it.
  final List<String> reasons;

  @override
  String toString() => reasons.isEmpty
      ? super.toString()
      : '${super.toString()}\n${reasons.map((r) => '  - $r').join('\n')}';
}

/// The native libvips library couldn't be loaded or is too old.
final class NativeLibraryException extends ImageTransformException {
  /// Creates the exception.
  const NativeLibraryException(super.message);
}
