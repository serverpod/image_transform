import 'backend.dart';
import 'options.dart';

/// Creates the backend for platforms without `dart:io` (the web).
Future<TransformBackend> createBackend(TransformerConfig config) =>
    throw UnsupportedError(
      'image_transform is not supported on this platform (no dart:io). '
      'Web support is planned via wasm-vips.',
    );
