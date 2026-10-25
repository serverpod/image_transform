// Resizes an image into a responsive WebP set, a square JPEG avatar and a
// tiny placeholder.
//
//   dart run example/image_transform_example.dart photo.jpg out/
import 'dart:io';

import 'package:image_transform/image_transform.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: image_transform_example <image> <output-dir>');
    exitCode = 64;
    return;
  }
  final source = args[0];
  final outDir = Directory(args[1])..createSync(recursive: true);

  final transformer = await ImageTransformer.create();
  stdout.writeln(
    'Backend: ${transformer.info.kind.name}, '
    'libvips ${transformer.info.vipsVersion}',
  );

  try {
    final result = await transformer.transform(ImageInput.file(source), [
      for (final width in [480, 960, 1600])
        ImageOutput(
          name: 'w$width',
          resize: Resize.fit(width: width),
          to: OutputTarget.file('${outDir.path}/w$width.webp'),
        ),
      ImageOutput(
        name: 'avatar',
        resize: const Resize.cover(256, 256, crop: Crop.attention()),
        encode: const Encode.jpeg(quality: 82),
        to: OutputTarget.file('${outDir.path}/avatar.jpg'),
      ),
    ], placeholder: const PlaceholderOptions());

    final info = result.source;
    stdout.writeln('Source: ${info.format.name} ${info.width}×${info.height}');
    for (final output in result.outputs) {
      switch (output) {
        case OutputSuccess():
          stdout.writeln(
            '  ${output.name}: ${output.width}×${output.height}, '
            '${output.byteLength} bytes → ${output.path}',
          );
        case OutputFailure(:final error):
          stdout.writeln('  ${output.name}: failed (${error.message})');
      }
    }
    stdout.writeln('Placeholder: ${result.placeholder?.dataUri.length} chars');
  } on ImageTransformException catch (e) {
    stderr.writeln('Could not transform $source: ${e.message}');
    exitCode = 1;
  } finally {
    await transformer.close();
  }
}
