# image_transform

Fast, safe image transformations for Dart and Flutter, powered by
[libvips](https://www.libvips.org/). One call decodes an image once and
produces any number of outputs: resized, smart-cropped, rotated upright,
converted to sRGB, stripped of metadata (including GPS), and encoded as WebP,
JPEG or PNG, with an optional tiny placeholder.

> **Status: 0.1 (milestone L1).** The API is complete; only the **CLI
> backend** is implemented. It needs the libvips command-line tools ≥ 8.15
> (`brew install vips`, `apt install libvips-tools`). The in-process FFI
> backend with bundled native libraries (all platforms including iOS and
> Android) is next.

## Quick start

```dart
import 'package:image_transform/image_transform.dart';

final transformer = await ImageTransformer.create();

final result = await transformer.transform(
  ImageInput.file('photo.jpg'),
  [
    for (final w in [480, 960, 1600])
      ImageOutput(name: 'w$w', resize: Resize.fit(width: w), to: OutputTarget.file('out/w$w.webp')),
    const ImageOutput(name: 'avatar', resize: Resize.cover(256, 256, crop: Crop.attention()), encode: Encode.jpeg()),
  ],
  placeholder: const PlaceholderOptions(),
);

print(result['w960'].width);               // measured, never upscaled
print(result.placeholder!.dataUri);         // data:image/webp;base64,…
final avatarJpeg = result['avatar'].bytes!;
```

Or, for the simple case:

```dart
final webp = await transformBytes(bytes, resize: const Resize.fit(width: 1024));
```

## What it does by default

| | Default |
|-|---------|
| Formats in | JPEG, PNG, WebP, GIF (including animated), detected by content |
| Formats out | WebP (animated when the source is), JPEG (alpha flattened onto white), PNG |
| Orientation | EXIF orientation applied |
| Colour | Converted to sRGB (CMYK, Display P3 and so on are honoured) |
| Metadata | All stripped (EXIF incl. GPS, XMP, IPTC, ICC) |
| Size | Never upscaled (`upscale: true` to allow) |
| Untrusted input | Header-only probe with format allow-list, pixel/frame/byte limits and strict decoding before any pixels are decoded; libvips' untrusted loaders blocked |

## Resizing

- `Resize.fit(width:, height:)` fits inside a box, keeping the aspect ratio.
- `Resize.cover(w, h, crop:)` fills the box exactly, with `Crop.centre()`, `Crop.attention()` (faces, objects), `Crop.entropy()` (detail) or `Crop.focal(x, y)`.
- `ImageTransformer.plan()` predicts output sizes without processing, so a UI can lay out an image before it's ready.

Animated inputs: fit and cover resize every frame. Attention and entropy crops
use the centre on animated images, and focal crops use the first frame.

## Errors

Problems with the source throw: `UnsupportedFormatException`,
`SourceLimitsException`, `DecodeException`. Problems with one output (an
encode failure, a timeout) are returned as `OutputFailure` in the result, so
the other outputs aren't lost. libvips messages are sanitised (no file paths).

## Backends

| Backend | Status | Isolation |
|---------|--------|-----------|
| CLI (`vips` child processes) | ✅ Linux, macOS, Windows | Each operation runs in its own process with a hard timeout. A crash or hang can't take your app down. Recommended for servers handling untrusted uploads. |
| FFI (in-process, bundled libvips) | Planned (L2–L4) | Same process, lowest overhead; all native platforms including iOS and Android. |

## Development

```bash
dart test            # unit tests + libvips conformance tests (needs vips on PATH)
dart test -x vips    # unit tests only
dart run tool/generate_fixtures.dart   # regenerate test/fixtures (needs vips)
```

## License

BSD 3-Clause. libvips itself is LGPL-2.1-or-later. The CLI backend uses
whatever libvips you've installed.
