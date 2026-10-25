import 'package:meta/meta.dart';

import 'inputs_outputs.dart';
import 'options.dart';
import 'planning.dart';
import 'results.dart';
import 'types.dart';

/// A source made available to a backend (e.g. spooled to a temp file).
@internal
abstract interface class PreparedSource {
  /// Encoded size in bytes.
  int get byteLength;
}

/// What every backend implements. Validation, planning, limits and result
/// shaping live above this interface, in `CoreTransformer`.
@internal
abstract interface class TransformBackend {
  BackendInfo get info;

  /// Makes [input] available. Throws `SourceLimitsException` when it's larger
  /// than [maxBytes].
  Future<PreparedSource> prepare(ImageInput input, {int? maxBytes});

  /// Reads the header. Throws `UnsupportedFormatException` for non-images.
  Future<ImageInfo> probe(PreparedSource source);

  /// Renders [outputs]. Per-output problems become [OutputFailure]s; problems
  /// with the source itself (e.g. `DecodeException`) are thrown.
  Future<List<OutputOutcome>> render(
    PreparedSource source,
    ImageInfo info,
    List<PlannedOutput> outputs,
    TransformOptions options,
    CancellationToken? cancel,
  );

  /// Renders the placeholder.
  Future<Placeholder> placeholder(
    PreparedSource source,
    ImageInfo info,
    PlaceholderOptions placeholder,
    TransformOptions options,
  );

  /// Frees what [prepare] allocated.
  Future<void> release(PreparedSource source);

  Future<void> close();
}
