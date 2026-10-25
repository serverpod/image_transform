import '../backend.dart';
import '../exceptions.dart';
import '../ffi/ffi_backend.dart';
import '../options.dart';
import '../types.dart';
import 'cli_backend.dart';

/// Picks and creates a backend (specs/03 §3.4).
Future<TransformBackend> createBackend(TransformerConfig config) async {
  switch (config.backend) {
    case BackendPreference.ffi:
      return FfiBackend.create(config);
    case BackendPreference.cli:
      return CliBackend.create(config);
    case BackendPreference.auto:
      final List<String> reasons;
      try {
        return await FfiBackend.create(config);
      } on BackendUnavailableException catch (e) {
        reasons = e.reasons;
      }
      try {
        return await CliBackend.create(config, reasons: reasons);
      } on BackendUnavailableException catch (e) {
        throw BackendUnavailableException(
          'No image_transform backend is available',
          reasons: e.reasons,
        );
      }
  }
}
