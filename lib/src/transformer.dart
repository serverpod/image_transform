import 'package:meta/meta.dart';

import 'backend.dart';
import 'backend_factory.dart';
import 'exceptions.dart';
import 'inputs_outputs.dart';
import 'options.dart';
import 'planning.dart';
import 'results.dart';
import 'types.dart';

/// Transforms images with libvips. Create one with [create] and reuse it.
abstract interface class ImageTransformer {
  /// Picks a backend and initialises it.
  ///
  /// Throws [BackendUnavailableException] with actionable reasons if no
  /// backend is usable, or [UnsupportedError] on the web.
  static Future<ImageTransformer> create([
    TransformerConfig config = const TransformerConfig(),
  ]) async => CoreTransformer(config, await createBackend(config));

  static Future<ImageTransformer>? _shared;

  /// A lazily created, process-wide instance with the default configuration.
  static Future<ImageTransformer> get shared => _shared ??= () async {
    try {
      return await create();
    } catch (_) {
      _shared = null;
      rethrow;
    }
  }();

  /// The backend in use.
  BackendInfo get info;

  /// Reads the header of [input] without decoding pixels, and checks it
  /// against the allowed formats and limits.
  Future<ImageInfo> probe(
    ImageInput input, {
    TransformOptions options = const TransformOptions(),
  });

  /// Produces [outputs] (and optionally a [placeholder]) from [input].
  ///
  /// Problems with the source throw; problems with individual outputs are
  /// reported as [OutputFailure]s in the result.
  Future<TransformResult> transform(
    ImageInput input,
    List<ImageOutput> outputs, {
    TransformOptions options = const TransformOptions(),
    PlaceholderOptions? placeholder,
    CancellationToken? cancel,
  });

  /// Predicts the dimensions of [output] without running libvips.
  OutputPlan plan(
    ImageInfo source,
    ImageOutput output, {
    TransformOptions options = const TransformOptions(),
  });

  /// Releases the backend. The transformer can't be used afterwards.
  Future<void> close();
}

/// Backend-independent implementation of [ImageTransformer].
@internal
final class CoreTransformer implements ImageTransformer {
  CoreTransformer(this._config, this._backend);

  final TransformerConfig _config;
  final TransformBackend _backend;
  var _closed = false;

  @override
  BackendInfo get info => _backend.info;

  SourceLimits _limits(TransformOptions options) =>
      options.limits ?? _config.limits;

  @override
  Future<ImageInfo> probe(
    ImageInput input, {
    TransformOptions options = const TransformOptions(),
  }) async {
    _checkOpen();
    final limits = _limits(options);
    final source = await _backend.prepare(
      input,
      maxBytes: limits.maxInputBytes,
    );
    try {
      final info = await _backend.probe(source);
      checkSource(info, _config.allowedFormats, limits, options);
      return info;
    } finally {
      await _backend.release(source);
    }
  }

  @override
  Future<TransformResult> transform(
    ImageInput input,
    List<ImageOutput> outputs, {
    TransformOptions options = const TransformOptions(),
    PlaceholderOptions? placeholder,
    CancellationToken? cancel,
  }) async {
    _checkOpen();
    if (outputs.isEmpty && placeholder == null) {
      throw const InvalidTransformException(
        'Nothing to do: no outputs and no placeholder',
        field: 'outputs',
      );
    }
    validateRequest(outputs, placeholder);
    if (cancel?.isCancelled ?? false) throw const TransformCancelledException();

    final stopwatch = Stopwatch()..start();
    final limits = _limits(options);
    final source = await _backend.prepare(
      input,
      maxBytes: limits.maxInputBytes,
    );
    try {
      final info = await _backend.probe(source);
      checkSource(info, _config.allowedFormats, limits, options);
      final planned = [
        for (var i = 0; i < outputs.length; i++)
          planOutput(info, outputs[i], options, index: i),
      ];
      final outcomes = planned.isEmpty
          ? const <OutputOutcome>[]
          : await _backend.render(source, info, planned, options, cancel);

      Placeholder? preview;
      if (placeholder != null && !(cancel?.isCancelled ?? false)) {
        try {
          preview = await _backend.placeholder(
            source,
            info,
            placeholder,
            options,
          );
        } on EncodeException {
          preview = null;
        } on TransformTimeoutException {
          preview = null;
        }
      }
      return TransformResult(
        source: info,
        outputs: List.unmodifiable(outcomes),
        placeholder: preview,
        elapsed: stopwatch.elapsed,
      );
    } finally {
      await _backend.release(source);
    }
  }

  @override
  OutputPlan plan(
    ImageInfo source,
    ImageOutput output, {
    TransformOptions options = const TransformOptions(),
  }) => planOutput(source, output, options).plan;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _backend.close();
  }

  void _checkOpen() {
    if (_closed) throw StateError('ImageTransformer has been closed');
  }
}
