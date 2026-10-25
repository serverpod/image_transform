import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// The result of running one process.
final class ProcessOutcome {
  /// Creates an outcome.
  const ProcessOutcome(
    this.exitCode,
    this.stdout,
    this.stderr, {
    this.timedOut = false,
  });

  /// Process exit code.
  final int exitCode;

  /// Captured standard output.
  final String stdout;

  /// Captured standard error.
  final String stderr;

  /// Whether the process was killed for exceeding its timeout.
  final bool timedOut;

  /// Whether the process exited with 0 in time.
  bool get succeeded => exitCode == 0 && !timedOut;
}

/// Runs processes with a hard timeout, limited parallelism and tracking, so
/// [killAll] can stop everything on close.
final class ProcessRunner {
  /// Creates a runner allowing [maxParallel] concurrent processes.
  ProcessRunner({required int maxParallel, required this.environment})
    : _maxParallel = maxParallel < 1 ? 1 : maxParallel;

  final int _maxParallel;

  /// Environment for every process.
  final Map<String, String> environment;
  final _running = <Process>{};
  final _waiting = Queue<Completer<void>>();
  var _active = 0;
  var _closed = false;

  /// Runs [executable] with [arguments] (never through a shell), using
  /// [environment] instead of the runner's default when given.
  Future<ProcessOutcome> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    await _acquire();
    try {
      if (_closed) throw StateError('ProcessRunner is closed');
      final process = await Process.start(
        executable,
        arguments,
        environment: environment ?? this.environment,
        workingDirectory: workingDirectory,
        runInShell: false,
      );
      _running.add(process);
      var timedOut = false;
      final timer = Timer(timeout, () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
      });
      final stdout = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final stderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final exitCode = await process.exitCode;
      timer.cancel();
      _running.remove(process);
      return ProcessOutcome(
        exitCode,
        await stdout,
        await stderr,
        timedOut: timedOut,
      );
    } finally {
      _release();
    }
  }

  /// Kills all running processes and rejects new ones.
  void killAll() {
    _closed = true;
    for (final process in _running) {
      process.kill(ProcessSignal.sigkill);
    }
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    }
  }

  Future<void> _acquire() async {
    if (_active < _maxParallel) {
      _active++;
      return;
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    await completer.future;
    _active++;
  }

  void _release() {
    _active--;
    if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
  }
}
