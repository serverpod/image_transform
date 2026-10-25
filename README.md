# image_transform

Fast, safe image transformations for Dart and Flutter, powered by
[libvips](https://www.libvips.org/). One call decodes an image once and
produces any number of outputs: resized, smart-cropped, rotated upright,
converted to sRGB, stripped of metadata (including GPS), and encoded as WebP,
JPEG or PNG, with an optional tiny placeholder.

> **Status: 0.1.** The API is complete, with two backends: an **in-process
> FFI backend** with a **prebuilt libvips downloaded automatically** for
> macOS, Linux and Windows (nothing to install), and a **CLI backend** that
> runs the libvips command-line tools in child processes. iOS and Android
> come later (they need our own libvips build).

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

All work happens off the calling isolate (worker isolates for FFI, child
processes for CLI), so it's safe to call from a Flutter UI or a server
request handler.

## What it does by default

| | Default |
|-|---------|
| Formats in | JPEG, PNG, WebP, GIF (including animated), detected by content |
| Formats out | WebP (animated when the source is), JPEG (alpha flattened onto white), PNG |
| Orientation | EXIF orientation applied |
| Colour | Converted to sRGB (CMYK, Display P3 and so on are honoured) |
| Metadata | All stripped (EXIF incl. GPS, XMP, IPTC, ICC) |
| Size | Never upscaled (`upscale: true` to allow) |
| Untrusted input | Header-only probe with format allow-list, pixel/frame/byte limits and strict decoding before any pixels are decoded; every other libvips loader blocked |

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

| Backend | Platforms | Isolation |
|---------|-----------|-----------|
| **FFI** (default) | macOS, Linux (glibc, musl), Windows; x64 and arm64 | In-process on a pool of worker isolates; lowest overhead. A libvips crash would take the process down. |
| **CLI** | Linux, macOS, Windows with libvips ≥ 8.15 installed (`brew install vips`, `apt install libvips-tools`) | Each operation runs in its own process with a hard timeout. Recommended for servers handling untrusted uploads at scale. |

`BackendPreference.auto` (the default) uses FFI when the native library is
available, otherwise the CLI. `ImageTransformer.info.reasons` says why.

## Native library (build hook)

The package's build hook downloads a prebuilt libvips for the target from
this repository's [GitHub releases](https://github.com/serverpod/image_transform/releases),
verifies its SHA-256 and bundles it with your app (`dart run`, `dart test`,
`dart build cli`, `flutter build`). Configure it in your app's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    image_transform:
      libvips: bundled            # bundled (default) | system | none
      library_dir: path/to/dir    # use your own libvips.{dylib,so,dll}
      download_base_url: https:// # mirror of the release assets
      allow_download: false       # never download
      require_native: true        # fail the build instead of warning
```

- A failed download or an unsupported platform only logs a warning; the FFI backend is then unavailable and `auto` falls back to the CLI.
- `libvips: none` skips the download (e.g. CLI-only servers).
- **Use `dart build cli`, not `dart compile exe`:** `dart compile` doesn't support packages with build hooks.

## Development

```bash
dart run tool/fetch_sharp_libvips.dart   # host libvips into native/out/ (used by the hook)
dart test                                # everything (CLI tests need vips on PATH)
dart test -t ffi                         # FFI backend only
dart test -x vips -x ffi                 # unit tests only
dart run tool/generate_fixtures.dart     # regenerate test/fixtures (needs vips)
```

Specification: [`specs/`](specs/README.md).

## License

The Dart code is BSD 3-Clause. The prebuilt native libraries are the
[sharp-libvips](https://github.com/lovell/sharp-libvips) builds of libvips,
repackaged unchanged, and are **LGPL-3.0-or-later** as a whole (components keep
their own licences; see `THIRD_PARTY_NOTICES.md` in each native release, which
also carries the corresponding source). The CLI backend uses whatever libvips
you've installed.
