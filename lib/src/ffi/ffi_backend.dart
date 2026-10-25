import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../backend.dart';
import '../exceptions.dart';
import '../inputs_outputs.dart';
import '../options.dart';
import '../planning.dart';
import '../results.dart';
import '../types.dart';
import '../vips_text.dart';
import 'render.dart';
import 'vips.dart';

/// Minimum libvips version (needed for the `keep=` save option).
const _minimumMajor = 8, _minimumMinor = 15;

final class _FfiSource implements PreparedSource {
  _FfiSource(this.worker, this.id, this.byteLength);

  final _Worker worker;
  final int id;
  @override
  final int byteLength;
}

/// libvips in-process through `dart:ffi` (specs/03 §3.1). All libvips calls
/// block, so they run on a pool of long-lived worker isolates; the calling
/// isolate (e.g. a Flutter UI or a server request handler) only awaits.
final class FfiBackend implements TransformBackend {
  FfiBackend._(this._workers, this.info);

  /// Loads the native library, checks its version and starts the workers.
  /// Throws [BackendUnavailableException] if the library isn't available.
  static Future<FfiBackend> create(
    TransformerConfig config, {
    List<String> reasons = const [],
  }) async {
    final String version;
    try {
      version = vipsVersionString();
    } catch (e) {
      throw BackendUnavailableException(
        'Native libvips not available',
        reasons: [
          ...reasons,
          'ffi: the bundled libvips is not available for this platform or '
              'build ($e). Check the image_transform build hook output, or '
              'set the user-define image_transform.libvips: system.',
        ],
      );
    }
    final parts = version.split('.').map(int.parse).toList();
    if (parts[0] < _minimumMajor ||
        (parts[0] == _minimumMajor && parts[1] < _minimumMinor)) {
      throw BackendUnavailableException(
        'libvips too old',
        reasons: [
          ...reasons,
          'ffi: libvips $version found, but $_minimumMajor.$_minimumMinor or '
              'newer is required.',
        ],
      );
    }
    // libvips initialisation and loader blocking are process-wide and not
    // safe to run from several threads at once, so they happen here, once,
    // before any worker starts.
    try {
      initVips(
        threads: config.vipsThreads,
        allowedFormats: config.allowedFormats,
      );
    } on VipsError catch (e) {
      throw BackendUnavailableException(
        'libvips failed to initialise',
        reasons: [...reasons, 'ffi: ${e.message}'],
      );
    }
    final count =
        config.workers ??
        (Platform.isAndroid || Platform.isIOS
            ? 1
            : (Platform.numberOfProcessors ~/ 2).clamp(1, 64));
    final workers = await Future.wait([
      for (var i = 0; i < count; i++) _Worker.spawn(),
    ]);
    return FfiBackend._(
      workers,
      BackendInfo(
        kind: BackendKind.ffi,
        vipsVersion: version,
        reasons: [
          ...reasons,
          'ffi: using the native libvips $version with $count worker isolate'
              '${count == 1 ? '' : 's'}',
        ],
      ),
    );
  }

  final List<_Worker> _workers;
  var _nextId = 0;

  @override
  final BackendInfo info;

  _Worker _pick() => _workers.reduce((a, b) => a.load <= b.load ? a : b);

  @override
  Future<PreparedSource> prepare(ImageInput input, {int? maxBytes}) async {
    final Uint8List bytes;
    switch (input) {
      case FileInput(:final path):
        final file = File(path);
        _checkBytes(await file.length(), maxBytes);
        bytes = await file.readAsBytes();
      case BytesInput(bytes: final b):
        _checkBytes(b.length, maxBytes);
        bytes = b;
      case StreamInput(:final stream):
        final builder = BytesBuilder(copy: false);
        await for (final chunk in stream) {
          builder.add(chunk);
          _checkBytes(builder.length, maxBytes);
        }
        bytes = builder.takeBytes();
      default:
        throw ArgumentError.value(input, 'input', 'Unsupported input');
    }
    final worker = _pick();
    final id = _nextId++;
    await worker.call(_Prepare(id, TransferableTypedData.fromList([bytes])));
    return _FfiSource(worker, id, bytes.length);
  }

  static void _checkBytes(int length, int? maxBytes) {
    if (maxBytes != null && length > maxBytes) {
      throw SourceLimitsException(
        'maxInputBytes exceeded: $length > $maxBytes',
        limit: 'maxInputBytes',
        actual: length,
        max: maxBytes,
      );
    }
  }

  @override
  Future<ImageInfo> probe(PreparedSource source) async {
    final s = source as _FfiSource;
    final fields = await s.worker.call(_Probe(s.id)) as Map<String, String>;
    return imageInfoFromHeader(fields, byteLength: s.byteLength);
  }

  @override
  Future<List<OutputOutcome>> render(
    PreparedSource source,
    ImageInfo info,
    List<PlannedOutput> outputs,
    TransformOptions options,
    CancellationToken? cancel,
  ) async {
    final s = source as _FfiSource;
    final outcomes = <OutputOutcome>[];
    for (final planned in outputs) {
      final name = planned.output.name;
      if (cancel?.isCancelled ?? false) {
        outcomes.add(
          OutputFailure(name: name, error: const TransformCancelledException()),
        );
        continue;
      }
      try {
        final r =
            await s.worker.call(_Render(s.id, info, planned, options))
                as _Rendered;
        outcomes.add(await _success(planned, r));
      } on DecodeException {
        rethrow; // A source problem: abort the whole call.
      } on ImageTransformException catch (e) {
        outcomes.add(OutputFailure(name: name, error: e));
      } on FileSystemException catch (e) {
        outcomes.add(
          OutputFailure(
            name: name,
            error: EncodeException('Could not write the output: ${e.message}'),
          ),
        );
      }
    }
    return outcomes;
  }

  static var _tempCounter = 0;

  Future<OutputSuccess> _success(PlannedOutput planned, _Rendered r) async {
    final bytes = r.bytes.materialize().asUint8List();
    Uint8List? inMemory;
    String? path;
    switch (planned.output.to) {
      case FileTarget(path: final destination):
        final target = File(destination);
        await target.parent.create(recursive: true);
        final temp = File('$destination.tmp-$pid-${_tempCounter++}');
        await temp.writeAsBytes(bytes, flush: true);
        try {
          await temp.rename(destination);
        } catch (_) {
          if (await temp.exists()) await temp.delete();
          rethrow;
        }
        path = destination;
      default:
        inMemory = bytes;
    }
    return OutputSuccess(
      name: planned.output.name,
      width: r.width,
      height: r.height,
      frames: r.frames,
      byteLength: bytes.length,
      format: planned.output.encode.format,
      clamped: planned.plan.clamped,
      bytes: inMemory,
      path: path,
    );
  }

  @override
  Future<Placeholder> placeholder(
    PreparedSource source,
    ImageInfo info,
    PlaceholderOptions placeholder,
    TransformOptions options,
  ) async {
    final s = source as _FfiSource;
    final r =
        await s.worker.call(_Placeholder(s.id, info, placeholder, options))
            as _Rendered;
    return Placeholder(
      bytes: r.bytes.materialize().asUint8List(),
      width: r.width,
      height: r.height,
      format: placeholder.encode.format,
    );
  }

  @override
  Future<void> release(PreparedSource source) async {
    final s = source as _FfiSource;
    await s.worker.call(_Release(s.id));
  }

  @override
  Future<void> close() async {
    await Future.wait([for (final w in _workers) w.close()]);
  }
}

// ------------------------------------------------------------ messages

sealed class _Request {
  const _Request();
}

final class _Prepare extends _Request {
  const _Prepare(this.id, this.bytes);
  final int id;
  final TransferableTypedData bytes;
}

final class _Probe extends _Request {
  const _Probe(this.id);
  final int id;
}

final class _Render extends _Request {
  const _Render(this.id, this.info, this.planned, this.options);
  final int id;
  final ImageInfo info;
  final PlannedOutput planned;
  final TransformOptions options;
}

final class _Placeholder extends _Request {
  const _Placeholder(this.id, this.info, this.placeholder, this.options);
  final int id;
  final ImageInfo info;
  final PlaceholderOptions placeholder;
  final TransformOptions options;
}

final class _Release extends _Request {
  const _Release(this.id);
  final int id;
}

final class _Shutdown extends _Request {
  const _Shutdown();
}

final class _Rendered {
  _Rendered(RenderedImage image)
    : bytes = TransferableTypedData.fromList([image.bytes]),
      width = image.width,
      height = image.height,
      frames = image.frames;

  final TransferableTypedData bytes;
  final int width;
  final int height;
  final int frames;
}

/// A worker isolate: owns the sources prepared on it and runs libvips calls
/// one at a time.
final class _Worker {
  _Worker._(this._isolate, this._send, this._receive) {
    _receive.listen(_onReply);
  }

  static Future<_Worker> spawn() async {
    final receive = ReceivePort();
    final ready = Completer<SendPort>();
    final setup = RawReceivePort((Object? message) {
      if (message is SendPort) {
        ready.complete(message);
      } else {
        ready.completeError(message ?? StateError('worker failed to start'));
      }
    });
    try {
      final isolate = await Isolate.spawn(
        _workerMain,
        setup.sendPort,
        debugName: 'image_transform worker',
        errorsAreFatal: false,
      );
      final send = await ready.future;
      return _Worker._(isolate, send, receive);
    } finally {
      setup.close();
    }
  }

  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _receive;
  final _pending = <int, Completer<Object?>>{};
  var _nextCall = 0;

  /// Calls queued or running on this worker.
  int get load => _pending.length;

  Future<Object?> call(_Request request) {
    final id = _nextCall++;
    final completer = _pending[id] = Completer<Object?>();
    _send.send((id, _receive.sendPort, request));
    return completer.future;
  }

  void _onReply(Object? message) {
    final (id, ok, value) = message! as (int, bool, Object?);
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (ok) {
      completer.complete(value);
    } else {
      completer.completeError(value!);
    }
  }

  Future<void> close() async {
    try {
      await call(const _Shutdown()).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Fall through to kill.
    }
    _receive.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// Worker entry point. libvips is already initialised by the creating
/// isolate (see [FfiBackend.create]).
void _workerMain(SendPort ready) {
  final sources = <int, VipsBlob>{};
  final port = RawReceivePort();
  port.handler = (Object? message) {
    final (id, reply, request) = message! as (int, SendPort, _Request);
    try {
      final Object? result = switch (request) {
        _Prepare(:final id, :final bytes) => () {
          sources[id] = VipsBlob.copy(bytes.materialize().asUint8List());
          return null;
        }(),
        _Probe(:final id) => probeSource(sources[id]!),
        _Render(:final id, :final info, :final planned, :final options) =>
          _Rendered(renderOutput(sources[id]!, info, planned, options)),
        _Placeholder(
          :final id,
          :final info,
          :final placeholder,
          :final options,
        ) =>
          _Rendered(
            renderPlaceholder(sources[id]!, info, placeholder, options),
          ),
        _Release(:final id) => () {
          sources.remove(id)?.dispose();
          return null;
        }(),
        _Shutdown() => () {
          for (final s in sources.values) {
            s.dispose();
          }
          sources.clear();
          return null;
        }(),
      };
      reply.send((id, true, result));
      if (request is _Shutdown) port.close();
    } on ImageTransformException catch (e) {
      reply.send((id, false, e));
    } catch (e) {
      reply.send((id, false, EncodeException('libvips failed: $e')));
    }
  };
  ready.send(port.sendPort);
}
