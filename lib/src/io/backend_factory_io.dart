import '../backend.dart';
import '../exceptions.dart';
import '../options.dart';
import '../types.dart';
import 'cli_backend.dart';

const _ffiUnavailable = 'ffi: FFI backend not implemented yet (milestone L2)';

/// Picks and creates a backend (spec 03 §3.4).
Future<TransformBackend> createBackend(TransformerConfig config) async {
  switch (config.backend) {
    case BackendPreference.ffi:
      throw const BackendUnavailableException(
        'FFI backend not implemented yet (milestone L2)',
        reasons: [_ffiUnavailable],
      );
    case BackendPreference.cli:
      return CliBackend.create(config);
    case BackendPreference.auto:
      try {
        return await CliBackend.create(
          config,
          reasons: const [_ffiUnavailable],
        );
      } on BackendUnavailableException catch (e) {
        throw BackendUnavailableException(
          'No image_transform backend is available',
          reasons: e.reasons,
        );
      }
  }
}
