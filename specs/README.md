# `image_transform` — Specification

A high-level, safe and fast image transformation library for **Dart and
Flutter**, powered by [libvips](https://www.libvips.org/). One call decodes an
image once, then produces any number of outputs: resized, cropped, rotated
upright, colour-converted, metadata-stripped and encoded as WebP, JPEG or PNG.
A tiny placeholder can come out of the same call.

Pixtronaut is the first consumer, but the package is designed to be useful on
its own. Examples: resizing photos in a Flutter app before upload, generating
thumbnails in a Serverpod endpoint, or batch-optimising images in a CLI tool.

```dart
import 'package:image_transform/image_transform.dart';

final transformer = await ImageTransformer.create();
final result = await transformer.transform(ImageInput.file('photo.jpg'), [
  ImageOutput(name: 'w640', resize: Resize.fit(width: 640), encode: Encode.webp()),
  ImageOutput(name: 'avatar', resize: Resize.cover(256, 256, crop: Crop.attention()), encode: Encode.jpeg(quality: 82)),
]);
final avatarBytes = result['avatar'].bytes;
```

## Documents

| # | Document | Contents |
|---|----------|----------|
| 1 | [API](01-api.md) | Public Dart API, types, errors, usage from Dart servers and Flutter |
| 2 | [Processing semantics](02-semantics.md) | Probe, limits, resize geometry, colour, metadata, encoders, animation, placeholder |
| 3 | [Backends](03-backends.md) | FFI backend (in-process, all native platforms), CLI backend (process-isolated, desktop/server), selection, isolates |
| 4 | [Native libraries](04-native-libraries.md) | Build hook, prebuilt libvips artifacts per platform, system/none modes, licensing |
| 5 | [Safety, testing and release](05-safety-testing-release.md) | Untrusted-input defaults, test matrix, fuzzing, benchmarks, versioning, milestones |

## Decisions

| Topic | Decision |
|-------|----------|
| Name | **`image_transform`**. It describes the whole job (decode → transform → encode), is engine-agnostic, matches Pixtronaut's "transformation" unit, and is free on pub.dev. |
| Home | Own repository `github.com/serverpod/image_transform`, published to pub.dev under the **serverpod.dev** publisher. (Assumed; confirm.) |
| Licence | Dart code **BSD-3-Clause** (like other Serverpod packages). Bundled native libvips is **LGPL-2.1-or-later**, and its dependencies keep their own permissive licences. No GPL components. |
| Platforms (v1) | **Linux** (x64, arm64; glibc and musl), **macOS** (arm64, x64), **Windows** (x64), **iOS** (device arm64, simulator arm64/x64), **Android** (arm64-v8a, x86_64). **Web is not supported** in v1: the package compiles for web, but `ImageTransformer.create()` throws `UnsupportedError`. (Assumed; confirm.) |
| Formats (v1) | Decode **JPEG, PNG, WebP, GIF** (incl. animated). Encode **WebP** (incl. animated), **JPEG**, **PNG**. AVIF/HEIC are a planned opt-in build variant (v1.x). (Assumed; confirm.) |
| Backends | **FFI** (default; libvips in-process through `dart:ffi`; every native platform) and **CLI** (spawns `vips`; process-isolated with hard timeouts; Linux/macOS/Windows only). Same API and semantics. |
| Native binaries | Shipped through a **Dart build hook** (native assets). The default `bundled` mode downloads a pinned, checksum-verified prebuilt libvips for the target. A `system` mode uses an installed libvips, and `none` skips native code (CLI only). |
| Threading | Every call is `async` and runs off the calling isolate (an isolate pool for FFI, child processes for CLI). This is safe to call from Flutter's UI isolate. |
| Scope | A curated, high-level operation set, **not** a complete libvips binding. Escape hatches can be added later without breaking the API. |
| SDK | Dart ≥ 3.10 and Flutter ≥ 3.38 (the first stable releases with build hooks; **verify** in L0). CI runs the current stable versions. |

## Goals

1. **One obvious way** to do the common things: fit/cover resize, smart crop, format conversion, quality presets, placeholders.
2. **Correct by default:** EXIF auto-rotation, sRGB conversion, metadata (GPS) stripping, no upscaling, no surprises on animated images.
3. **Safe on untrusted input:** format allow-list, pixel/frame limits, untrusted loaders blocked, a minimal compiled-in loader set.
4. **Fast and frugal:** libvips' shrink-on-load and streaming, with no full decode where it can be avoided. Low memory use matters for mobile.
5. **Identical behaviour across platforms and backends**, enforced by a shared conformance suite.
6. **Zero setup:** `dart pub add image_transform` works on every supported platform without installing anything.

## Non-goals (v1)

- Web support (a candidate for v2 via wasm-vips in a Web Worker).
- A general libvips binding (arbitrary operations, drawing, compositing, filters, text).
- Upscaling with AI or super-resolution; video; RAW camera formats; PDF/SVG rasterisation.
- AVIF/HEIC/JPEG XL in the default build (planned as an opt-in variant).
- Flutter `ui.Image` / widget integration (bytes in, bytes out; a companion package may follow).
