import 'dart:typed_data';

import 'inputs_outputs.dart';
import 'options.dart';
import 'transformer.dart';
import 'types.dart';

/// Resizes and/or re-encodes [input] with the shared transformer and returns
/// the encoded bytes.
Future<Uint8List> transformBytes(
  Uint8List input, {
  Resize? resize,
  Encode encode = const Encode.webp(),
  TransformOptions options = const TransformOptions(),
}) async {
  final transformer = await ImageTransformer.shared;
  final result = await transformer.transform(BytesInput(input), [
    ImageOutput(name: 'output', resize: resize, encode: encode),
  ], options: options);
  return result['output'].bytes!;
}

/// Reads the header of [input] with the shared transformer.
Future<ImageInfo> probeBytes(Uint8List input) async =>
    (await ImageTransformer.shared).probe(BytesInput(input));
