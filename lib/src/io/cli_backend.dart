import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../backend.dart';
import '../cli_args.dart';
import '../exceptions.dart';
import '../inputs_outputs.dart';
import '../options.dart';
import '../planning.dart';
import '../results.dart';
import '../types.dart';
import '../vips_text.dart';
import 'process_runner.dart';

/// Minimum libvips version (needed for the `keep=` save option).
const minimumVipsVersion = (major: 8, minor: 15);

/// Every libvips process runs inside the call's temp directory and gets
/// relative, library-generated file names, so no user path (which could
/// contain spaces or libvips option syntax) ever reaches libvips.
const _sourceName = 'source';

final class _CliSource implements PreparedSource {
  _CliSource(this.directory, this.path, this.byteLength, this.knownPaths);

  final Directory directory;
  final String path;
  @override
  final int byteLength;
  final Map<String, String> knownPaths;

  /// Absolute path of [name] inside this source's temp directory.
  String resolve(String name) =>
      '${directory.path}${Platform.pathSeparator}$name';
}

/// Runs the libvips command-line tools in child processes (spec 03 §3.2).
final class CliBackend implements TransformBackend {
  CliBackend._(
    this._config,
    this._runner,
    this._internalEnvironment,
    this.info,
  );

  /// Checks that `vips` works and is new enough, then creates the backend.
  /// Throws [BackendUnavailableException] otherwise.
  static Future<CliBackend> create(
    TransformerConfig config, {
    List<String> reasons = const [],
  }) async {
    final environment = {
      ...Platform.environment,
      'VIPS_BLOCK_UNTRUSTED': '1',
      if (config.vipsThreads != null)
        'VIPS_CONCURRENCY': '${config.vipsThreads}',
      ...config.cli.environment,
    };
    ProcessResult result;
    try {
      result = await Process.run(config.cli.vips, [
        '--version',
      ], environment: environment);
    } on ProcessException catch (e) {
      throw BackendUnavailableException(
        'libvips CLI not found',
        reasons: [
          ...reasons,
          'cli: could not run "${config.cli.vips}" (${e.message}). Install libvips '
              '(e.g. `brew install vips` or `apt install libvips-tools`) or set CliConfig.vips.',
        ],
      );
    }
    final version = parseVipsVersion('${result.stdout}');
    if (result.exitCode != 0 || version == null) {
      throw BackendUnavailableException(
        'libvips CLI unusable',
        reasons: [
          ...reasons,
          'cli: "${config.cli.vips} --version" failed: ${result.stderr}',
        ],
      );
    }
    final tooOld =
        version.major < minimumVipsVersion.major ||
        (version.major == minimumVipsVersion.major &&
            version.minor < minimumVipsVersion.minor);
    final versionText = '${version.major}.${version.minor}.${version.patch}';
    if (tooOld) {
      throw BackendUnavailableException(
        'libvips too old',
        reasons: [
          ...reasons,
          'cli: libvips $versionText found, but ${minimumVipsVersion.major}.'
              '${minimumVipsVersion.minor} or newer is required.',
        ],
      );
    }
    // Steps that only read the library's own intermediates (`.v` files) must
    // not block untrusted loaders: VIPS_BLOCK_UNTRUSTED also blocks `vipsload`.
    final internalEnvironment = Map.of(environment)
      ..remove('VIPS_BLOCK_UNTRUSTED');
    final workers =
        config.workers ?? (Platform.numberOfProcessors ~/ 2).clamp(1, 64);
    return CliBackend._(
      config,
      ProcessRunner(maxParallel: workers, environment: environment),
      internalEnvironment,
      BackendInfo(
        kind: BackendKind.cli,
        vipsVersion: versionText,
        reasons: [
          ...reasons,
          'cli: using ${config.cli.vips} (libvips $versionText)',
        ],
      ),
    );
  }

  final TransformerConfig _config;
  final ProcessRunner _runner;
  final Map<String, String> _internalEnvironment;

  @override
  final BackendInfo info;

  CliConfig get _cli => _config.cli;

  // ---------------------------------------------------------------- sources

  @override
  Future<PreparedSource> prepare(ImageInput input, {int? maxBytes}) async {
    final base = Directory(_config.tempDirectory ?? Directory.systemTemp.path);
    await base.create(recursive: true);
    final dir = await base.createTemp('image_transform_');
    final path = '${dir.path}${Platform.pathSeparator}$_sourceName';
    final known = <String, String>{dir.path: '<tmp>'};
    try {
      final int length;
      switch (input) {
        case FileInput(path: final inputPath):
          final file = File(inputPath);
          length = await file.length();
          _checkBytes(length, maxBytes);
          known[file.absolute.path] = '<input>';
          known[inputPath] = '<input>';
          // A link (or copy) with a neutral name: the user's path could contain
          // libvips option syntax such as "[" or ",".
          try {
            await Link(path).create(file.absolute.path);
          } on FileSystemException {
            await file.copy(path);
          }
        case BytesInput(:final bytes):
          length = bytes.length;
          _checkBytes(length, maxBytes);
          await File(path).writeAsBytes(bytes, flush: true);
        case StreamInput(:final stream):
          length = await _spool(stream, File(path), maxBytes);
        default:
          throw ArgumentError.value(input, 'input', 'Unsupported input');
      }
      return _CliSource(dir, path, length, known);
    } catch (_) {
      await _deleteQuietly(dir);
      rethrow;
    }
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

  static Future<int> _spool(
    Stream<List<int>> stream,
    File file,
    int? maxBytes,
  ) async {
    final sink = file.openWrite();
    var length = 0;
    try {
      await for (final chunk in stream) {
        length += chunk.length;
        _checkBytes(length, maxBytes);
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    return length;
  }

  @override
  Future<void> release(PreparedSource source) =>
      _deleteQuietly((source as _CliSource).directory);

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }

  // ------------------------------------------------------------------ probe

  @override
  Future<ImageInfo> probe(PreparedSource source) async {
    final s = source as _CliSource;
    final outcome = await _runner.run(
      _cli.vipsheader,
      ['-a', _sourceName],
      timeout: _cli.processTimeout,
      workingDirectory: s.directory.path,
    );
    if (outcome.timedOut) {
      throw const TransformTimeoutException(
        'Reading the image header timed out',
      );
    }
    if (!outcome.succeeded) {
      final error = sanitizeVipsError(outcome.stderr, knownPaths: s.knownPaths);
      if (error.contains('not a known file format')) {
        throw UnsupportedFormatException('Not a supported image ($error)');
      }
      throw DecodeException(
        'Could not read the image header',
        vipsError: error,
      );
    }
    return imageInfoFromHeader(
      parseVipsHeader(outcome.stdout),
      byteLength: s.byteLength,
    );
  }

  // ----------------------------------------------------------------- render

  @override
  Future<List<OutputOutcome>> render(
    PreparedSource source,
    ImageInfo info,
    List<PlannedOutput> outputs,
    TransformOptions options,
    CancellationToken? cancel,
  ) async {
    final s = source as _CliSource;
    final outcomes = <OutputOutcome>[];
    for (final planned in outputs) {
      if (cancel?.isCancelled ?? false) {
        outcomes.add(
          OutputFailure(
            name: planned.output.name,
            error: const TransformCancelledException(),
          ),
        );
        continue;
      }
      outcomes.add(await _renderOne(s, info, planned, options));
    }
    return outcomes;
  }

  Future<OutputOutcome> _renderOne(
    _CliSource source,
    ImageInfo info,
    PlannedOutput planned,
    TransformOptions options,
  ) async {
    final name = planned.output.name;
    final encode = planned.output.encode;
    final output = 'out-${planned.index}.${encode.format.extension}';
    final intermediate = 'tmp-${planned.index}.v';
    try {
      final resize = planned.output.resize;
      final cover = planned.cover;
      final manualCrop =
          cover != null &&
          resize is CoverResize &&
          (resize.crop is FocalCrop || planned.loadAllFrames);
      await _vips(
        CliArgs.renderStep(
          planned,
          info,
          sourcePath: _sourceName,
          output: output,
          intermediate: intermediate,
          options: options,
          needsManualCrop: manualCrop,
        ),
        source,
        stage: _Stage.render,
      );
      if (manualCrop) {
        await _cropManually(
          source,
          planned,
          resize,
          cover,
          intermediate,
          output,
          options,
        );
        await _deleteFileQuietly(source.resolve(intermediate));
      }
      return await _collect(source, planned, output);
    } on DecodeException {
      rethrow; // A source problem: abort the whole call.
    } on ImageTransformException catch (e) {
      return OutputFailure(name: name, error: e);
    } on FileSystemException catch (e) {
      return OutputFailure(
        name: name,
        error: EncodeException('Could not write the output: ${e.message}'),
      );
    } finally {
      await _deleteFileQuietly(source.resolve(output));
      await _deleteFileQuietly(source.resolve(intermediate));
    }
  }

  /// Second step of focal crops and of crops on animated images: crop the
  /// resized intermediate (frame by frame when animated).
  Future<void> _cropManually(
    _CliSource source,
    PlannedOutput planned,
    CoverResize resize,
    CoverGeometry cover,
    String intermediate,
    String output,
    TransformOptions options,
  ) async {
    final crop = resize.crop;
    final (:left, :top) = crop is FocalCrop
        ? cover.focalOrigin(crop.x, crop.y)
        : (
            left: (cover.resizedWidth - cover.boxWidth) ~/ 2,
            top: (cover.resizedHeight - cover.boxHeight) ~/ 2,
          );
    final frames = planned.plan.frames;
    if (frames <= 1) {
      final save = CliArgs.saveOptions(planned.output.encode, options.metadata);
      await _vips(
        CliArgs.extractArea(
          intermediate,
          '$output$save',
          left,
          top,
          cover.boxWidth,
          cover.boxHeight,
        ),
        source,
        stage: _Stage.encode,
      );
      return;
    }
    final save = CliArgs.saveOptions(
      planned.output.encode,
      options.metadata,
      pageHeight: cover.boxHeight,
    );
    if (cover.resizedHeight == cover.boxHeight) {
      // Only columns are cropped: one extract over the whole frame stack.
      await _vips(
        CliArgs.extractArea(
          intermediate,
          '$output$save',
          left,
          0,
          cover.boxWidth,
          cover.boxHeight * frames,
        ),
        source,
        stage: _Stage.encode,
      );
      return;
    }
    // Rows are cropped inside each frame: extract each frame and rejoin.
    final framePaths = <String>[];
    try {
      for (var i = 0; i < frames; i++) {
        final framePath = 'frame-${planned.index}-$i.v';
        await _vips(
          CliArgs.extractArea(
            intermediate,
            framePath,
            left,
            i * cover.resizedHeight + top,
            cover.boxWidth,
            cover.boxHeight,
          ),
          source,
          stage: _Stage.encode,
        );
        framePaths.add(framePath);
      }
      await _vips(
        ['arrayjoin', framePaths.join(' '), '$output$save', '--across', '1'],
        source,
        stage: _Stage.encode,
      );
    } finally {
      for (final path in framePaths) {
        await _deleteFileQuietly(source.resolve(path));
      }
    }
  }

  Future<OutputSuccess> _collect(
    _CliSource source,
    PlannedOutput planned,
    String output,
  ) async {
    final header = await _runner.run(
      _cli.vipsheader,
      ['-a', output],
      timeout: _cli.processTimeout,
      workingDirectory: source.directory.path,
    );
    if (!header.succeeded) {
      throw EncodeException(
        'Could not measure the output',
        vipsError: sanitizeVipsError(
          header.stderr,
          knownPaths: source.knownPaths,
        ),
      );
    }
    final measured = imageInfoFromHeader(parseVipsHeader(header.stdout));
    final file = File(source.resolve(output));
    final length = await file.length();
    final target = planned.output.to;
    Uint8List? bytes;
    String? path;
    switch (target) {
      case FileTarget(path: final destination):
        await _writeAtomically(file, destination);
        path = destination;
      default:
        bytes = await file.readAsBytes();
    }
    return OutputSuccess(
      name: planned.output.name,
      width: measured.width,
      height: measured.height,
      frames: measured.frames,
      byteLength: length,
      format: planned.output.encode.format,
      clamped: planned.plan.clamped,
      bytes: bytes,
      path: path,
    );
  }

  static var _tempCounter = 0;

  static Future<void> _writeAtomically(File from, String destination) async {
    final target = File(destination);
    await target.parent.create(recursive: true);
    final temp = '$destination.tmp-$pid-${_tempCounter++}';
    await from.copy(temp);
    try {
      await File(temp).rename(destination);
    } catch (_) {
      await _deleteFileQuietly(temp);
      rethrow;
    }
  }

  // ------------------------------------------------------------ placeholder

  @override
  Future<Placeholder> placeholder(
    PreparedSource source,
    ImageInfo info,
    PlaceholderOptions placeholder,
    TransformOptions options,
  ) async {
    final s = source as _CliSource;
    final format = placeholder.encode.format;
    final output = 'placeholder.${format.extension}';
    try {
      await _vips(
        CliArgs.thumbnail(
          source: _sourceName,
          loadOptions: CliArgs.loadOptions(info.format, allFrames: false),
          output:
              '$output${CliArgs.saveOptions(placeholder.encode, MetadataPolicy.none)}',
          width: placeholder.size,
          height: placeholder.size,
          options: options,
        ),
        s,
        stage: _Stage.render,
      );
      final measured = await _runner.run(
        _cli.vipsheader,
        ['-a', output],
        timeout: _cli.processTimeout,
        workingDirectory: s.directory.path,
      );
      final header = imageInfoFromHeader(parseVipsHeader(measured.stdout));
      return Placeholder(
        bytes: await File(s.resolve(output)).readAsBytes(),
        width: header.width,
        height: header.height,
        format: format,
      );
    } finally {
      await _deleteFileQuietly(s.resolve(output));
    }
  }

  // ------------------------------------------------------------------ utils

  Future<void> _vips(
    List<String> arguments,
    _CliSource source, {
    required _Stage stage,
  }) async {
    final outcome = await _runner.run(
      _cli.vips,
      arguments,
      timeout: _cli.processTimeout,
      workingDirectory: source.directory.path,
      // Encode steps read only the library's own intermediates.
      environment: stage == _Stage.encode ? _internalEnvironment : null,
    );
    if (outcome.timedOut) {
      throw TransformTimeoutException(
        'libvips took longer than ${_cli.processTimeout.inSeconds}s',
      );
    }
    if (outcome.succeeded) return;
    final error = sanitizeVipsError(
      outcome.stderr,
      knownPaths: source.knownPaths,
    );
    if (stage == _Stage.render && looksLikeDecodeError(outcome.stderr)) {
      throw DecodeException('The image could not be decoded', vipsError: error);
    }
    throw EncodeException(
      'libvips failed (exit ${outcome.exitCode})',
      vipsError: error,
    );
  }

  static Future<void> _deleteFileQuietly(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  @override
  Future<void> close() async => _runner.killAll();
}

enum _Stage { render, encode }
