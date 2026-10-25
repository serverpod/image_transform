import 'dart:async';
import 'dart:typed_data';

import 'exceptions.dart';
import 'types.dart';

/// The outcome of one `ImageTransformer.transform` call.
final class TransformResult {
  /// Creates a result.
  const TransformResult({
    required this.source,
    required this.outputs,
    required this.elapsed,
    this.placeholder,
  });

  /// Header information about the source.
  final ImageInfo source;

  /// One outcome per requested output, in request order.
  final List<OutputOutcome> outputs;

  /// The placeholder, if requested and successful.
  final Placeholder? placeholder;

  /// Total processing time.
  final Duration elapsed;

  /// The successful output named [name]. Throws that output's error if it
  /// failed, or [ArgumentError] if no output has that name.
  OutputSuccess operator [](String name) {
    for (final outcome in outputs) {
      if (outcome.name != name) continue;
      return switch (outcome) {
        OutputSuccess() => outcome,
        OutputFailure(:final error) => throw error,
      };
    }
    throw ArgumentError.value(name, 'name', 'No such output');
  }

  /// Outputs that succeeded.
  Iterable<OutputSuccess> get successes => outputs.whereType<OutputSuccess>();

  /// Outputs that failed.
  Iterable<OutputFailure> get failures => outputs.whereType<OutputFailure>();

  /// Whether every output succeeded.
  bool get allSucceeded => outputs.every((o) => o is OutputSuccess);
}

/// The outcome of a single output.
sealed class OutputOutcome {
  const OutputOutcome(this.name);

  /// The output's name.
  final String name;
}

/// An output that was produced.
final class OutputSuccess extends OutputOutcome {
  /// Creates a success.
  const OutputSuccess({
    required String name,
    required this.width,
    required this.height,
    required this.frames,
    required this.byteLength,
    required this.format,
    required this.clamped,
    this.bytes,
    this.path,
  }) : super(name);

  /// Measured width.
  final int width;

  /// Measured height (of one frame).
  final int height;

  /// Frame count; more than 1 means animated.
  final int frames;

  /// Encoded size in bytes.
  final int byteLength;

  /// Encoded format.
  final ImageFormat format;

  /// The encoded bytes, for `OutputTarget.bytes()`.
  final Uint8List? bytes;

  /// The written file, for `OutputTarget.file()`.
  final String? path;

  /// Whether the requested size exceeded the source and was clamped.
  final bool clamped;

  /// Whether the output is animated.
  bool get isAnimated => frames > 1;
}

/// An output that failed. The other outputs are unaffected.
final class OutputFailure extends OutputOutcome {
  /// Creates a failure.
  const OutputFailure({required String name, required this.error})
    : super(name);

  /// Why it failed.
  final ImageTransformException error;
}

/// Cooperative cancellation for `ImageTransformer.transform`.
///
/// Checked between steps; remaining outputs become
/// [OutputFailure]s with a [TransformCancelledException].
final class CancellationToken {
  final _completer = Completer<void>();

  /// Requests cancellation.
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  /// Whether cancellation was requested.
  bool get isCancelled => _completer.isCompleted;

  /// Completes when cancellation is requested.
  Future<void> get whenCancelled => _completer.future;
}
