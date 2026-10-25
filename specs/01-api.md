# 1. API

One library, `package:image_transform/image_transform.dart`. Everything is
immutable value types plus one service object (`ImageTransformer`). There's no
dependency on Flutter, so the same API works in Dart servers, CLIs and Flutter
apps.

## 1.1 Creating a transformer

```dart
abstract interface class ImageTransformer {
  /// Picks a backend (see 03 §3.4) and initialises it. Cheap to call once per
  /// process; reuse the instance. Throws BackendUnavailableException with
  /// actionable instructions if no backend is usable, or UnsupportedError on web.
  static Future<ImageTransformer> create([TransformerConfig config = const TransformerConfig()]);

  /// A lazily created, process-wide default instance (used by the convenience functions).
  static Future<ImageTransformer> get shared;

  BackendInfo get info;   // backend kind, libvips version, available loaders/savers

  Future<ImageInfo> probe(ImageInput input, {TransformOptions options = const TransformOptions()});

  Future<TransformResult> transform(
    ImageInput input,
    List<ImageOutput> outputs, {
    TransformOptions options = const TransformOptions(),
    PlaceholderOptions? placeholder,          // null = none
    CancellationToken? cancel,
  });

  /// Predicts output dimensions without running libvips (pure geometry, 02 §2.4).
  OutputPlan plan(ImageInfo source, ImageOutput output, {TransformOptions options = const TransformOptions()});

  Future<void> close();   // stops isolates / kills child processes
}
```

```dart
final class TransformerConfig {
  const TransformerConfig({
    this.backend = BackendPreference.auto,     // auto | ffi | cli
    this.workers,                              // FFI isolates / CLI parallel processes. Default: platform-specific (03 §3.2)
    this.vipsThreads,                          // libvips worker threads per operation. Default: libvips default (cores)
    this.allowedFormats = const {ImageFormat.jpeg, ImageFormat.png, ImageFormat.webp, ImageFormat.gif},
    this.limits = SourceLimits.defaults,
    this.tempDirectory,                        // default: Directory.systemTemp
    this.cli = const CliConfig(),              // executable paths, per-process timeout
  });
}

final class CliConfig {
  const CliConfig({this.vips = 'vips', this.vipsheader = 'vipsheader',
                   this.processTimeout = const Duration(seconds: 60), this.environment = const {}});
}
```

## 1.2 Inputs

```dart
abstract base class ImageInput {
  const factory ImageInput.file(String path) = FileInput;
  const factory ImageInput.bytes(Uint8List bytes) = BytesInput;
  /// Spooled to memory (FFI) or a temp file (CLI). `maxBytes` defaults to SourceLimits.maxInputBytes.
  factory ImageInput.stream(Stream<List<int>> stream, {int? length}) = StreamInput;
}
```

The format is always detected from **content** (magic bytes), never from the
file extension.

## 1.3 Outputs

```dart
final class ImageOutput {
  const ImageOutput({
    required this.name,                        // unique within a call; used to look up results
    this.resize,                               // null = keep dimensions (re-encode only)
    this.encode = const Encode.webp(),
    this.to = const OutputTarget.bytes(),      // or OutputTarget.file(path)
  });
}

abstract base class Resize {
  /// Fit inside a box, keeping the aspect ratio. Width and/or height.
  const factory Resize.fit({int? width, int? height, bool upscale}) = FitResize;      // upscale: false
  /// Fill exactly width×height, cropping the overflow.
  const factory Resize.cover(int width, int height, {Crop crop, bool upscale}) = CoverResize; // crop: centre
}

abstract base class Crop {
  const factory Crop.centre() = CentreCrop;
  const factory Crop.attention() = AttentionCrop;   // saliency: faces/objects/skin/colour
  const factory Crop.entropy() = EntropyCrop;       // most detailed region
  const factory Crop.focal(double x, double y) = FocalCrop;  // 0..1, relative to the upright image
}

abstract base class Encode {
  const factory Encode.webp({int quality, bool lossless, int effort, bool smartSubsample, int? alphaQuality}) = WebpEncode;
  //                          80            false          4            true
  const factory Encode.jpeg({int quality, bool progressive, bool optimizeCoding, ChromaSubsampling subsampling}) = JpegEncode;
  //                          82            true                true                 auto
  const factory Encode.png({int compression, bool palette, int? colors}) = PngEncode;
  //                          6                false
}

abstract base class OutputTarget {
  const factory OutputTarget.bytes() = BytesTarget;
  const factory OutputTarget.file(String path) = FileTarget;   // written atomically (temp file + rename)
}
```

## 1.4 Options

```dart
final class TransformOptions {
  const TransformOptions({
    this.animation = AnimationMode.preserve,    // preserve | firstFrame
    this.autoOrient = true,                     // apply EXIF orientation
    this.color = ColorPolicy.srgb,              // srgb (convert) | preserve (keep embedded profile)
    this.metadata = MetadataPolicy.none,        // none | icc | all
    this.failOn = FailOn.error,                 // error | warning | none (how strict the decoder is)
    this.limits,                                // overrides TransformerConfig.limits for this call
  });
}

final class SourceLimits {
  const SourceLimits({this.maxInputBytes, this.maxPixels, this.maxFrames, this.maxAnimatedPixels});
  static const defaults = SourceLimits(
    maxInputBytes: 256 * 1024 * 1024,
    maxPixels: 268402689,          // 16383², the same default as sharp's limitInputPixels
    maxFrames: 1000,
    maxAnimatedPixels: 1000000000,
  );
  static const unlimited = SourceLimits();
}

final class PlaceholderOptions {
  const PlaceholderOptions({this.size = 24, this.encode = const Encode.webp(quality: 50, effort: 6)});
}
```

## 1.5 Results

```dart
final class TransformResult {
  final ImageInfo source;
  final List<OutputOutcome> outputs;          // same order as requested
  final Placeholder? placeholder;
  final Duration elapsed;

  OutputSuccess operator [](String name);      // throws the output's error if it failed
  Iterable<OutputSuccess> get successes;
  Iterable<OutputFailure> get failures;
  bool get allSucceeded;
}

sealed class OutputOutcome { String get name; }

final class OutputSuccess extends OutputOutcome {
  final int width, height;
  final int frames;                           // > 1 = animated
  final int byteLength;
  final ImageFormat format;
  final Uint8List? bytes;                     // for BytesTarget
  final String? path;                         // for FileTarget
  final bool clamped;                         // requested size exceeded the source and upscale was false
}

final class OutputFailure extends OutputOutcome {
  final ImageTransformException error;
}

final class ImageInfo {
  final ImageFormat format;                   // jpeg | png | webp | gif
  final String loader;                        // libvips loader nickname, e.g. "jpegload_buffer"
  final int width, height;                    // as stored (one frame)
  final int orientedWidth, orientedHeight;    // after EXIF orientation
  final int orientation;                      // 1..8
  final int frames;
  final bool hasAlpha;
  final ColorSpace colorSpace;                // srgb | rgb16 | grey | grey16 | cmyk | lab | other
  final bool hasIccProfile;
  final int? byteLength;
}

final class Placeholder {
  final Uint8List bytes;
  final int width, height;
  final ImageFormat format;
  String get dataUri;                         // "data:image/webp;base64,…"
}
```

**Source-level** problems (unsupported format, limits exceeded, undecodable
input) **throw** from `transform`. **Per-output** problems (encode failure,
file write error, cancellation part-way) become `OutputFailure`s, so
the successful outputs aren't lost.

## 1.6 Errors

```dart
abstract base class ImageTransformException implements Exception { String get message; }

final class UnsupportedFormatException extends ImageTransformException { final String? detectedLoader; }
final class SourceLimitsException     extends ImageTransformException { final String limit; final int actual, max; }
final class DecodeException           extends ImageTransformException { final String vipsError; }  // corrupt/truncated
final class EncodeException           extends ImageTransformException { final String vipsError; }
final class InvalidTransformException extends ImageTransformException { final String field; }     // bad parameters
final class TransformTimeoutException extends ImageTransformException {}                           // CLI backend
final class TransformCancelledException extends ImageTransformException {}
final class BackendUnavailableException extends ImageTransformException { final List<String> reasons; }
final class NativeLibraryException    extends ImageTransformException {}                           // load/version failure
```

`vipsError` strings are sanitised: file paths are replaced by placeholders,
and the length is capped at 1 KiB.

## 1.7 Convenience functions

For the 80% case, especially in Flutter:

```dart
/// Resize/convert bytes with the shared transformer.
Future<Uint8List> transformBytes(Uint8List input, {Resize? resize, Encode encode = const Encode.webp(), TransformOptions options = const TransformOptions()});

/// Probe bytes with the shared transformer.
Future<ImageInfo> probeBytes(Uint8List input);
```

## 1.8 Usage examples

**Flutter: shrink a camera photo before upload**

```dart
final picked = await ImagePicker().pickImage(source: ImageSource.camera);
final jpeg = await transformBytes(
  await picked!.readAsBytes(),
  resize: const Resize.fit(width: 2048, height: 2048),
  encode: const Encode.jpeg(quality: 85),
);   // runs off the UI isolate; EXIF rotation applied and GPS stripped
```

**Dart server: responsive set + avatar + placeholder from one decode**

```dart
final t = await ImageTransformer.create();
final r = await t.transform(
  ImageInput.file(upload.path),
  [
    for (final w in [480, 960, 1600])
      ImageOutput(name: 'w$w', resize: Resize.fit(width: w), to: OutputTarget.file('out/w$w.webp')),
    const ImageOutput(name: 'avatar', resize: Resize.cover(256, 256, crop: Crop.attention())),
  ],
  placeholder: const PlaceholderOptions(),
);
```

**Untrusted uploads on a server, with process isolation and hard timeouts**

```dart
final t = await ImageTransformer.create(const TransformerConfig(
  backend: BackendPreference.cli,
  limits: SourceLimits(maxInputBytes: 50 << 20, maxPixels: 100000000, maxFrames: 300, maxAnimatedPixels: 500000000),
));
```

## 1.9 API stability

- Value types are `final` classes with `const` constructors. New optional named parameters may be added in minor releases.
- Option hierarchies that will grow (`Resize`, `Crop`, `Encode`, `ImageInput`, `OutputTarget`, `ImageTransformException`) are **`abstract base`**, not `sealed`. New members (e.g. `Encode.avif`, `Resize.contain`) can then ship in **minor** releases without breaking users' exhaustive `switch`es. Users construct them only through the factory constructors.
- Only `OutputOutcome` (success | failure) is `sealed`, and it won't grow.
- `ImageFormat` and `ColorSpace` are enums with an `other` member, so new formats don't break exhaustive switches either.
