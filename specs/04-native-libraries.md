# 4. Native libraries

The FFI backend needs a libvips shared library for the **target** platform.
It's delivered through Dart's **build hooks** (native assets), so
`dart run`, `dart build cli`, `dart test` and `flutter build` for any
platform pick it up automatically, with no CocoaPods, Gradle or CMake glue.

## 4.1 Modes (hook user-define `libvips`)

```yaml
# in the consuming app's pubspec.yaml (optional; default is bundled)
hooks:
  user_defines:
    image_transform:
      libvips: bundled     # bundled | system | none
      # libvips_archive_dir: /path/to/mirror   # optional offline mirror for bundled mode
```

| Mode | Hook behaviour | Use when |
|------|----------------|----------|
| `bundled` (default) | Downloads the pinned prebuilt archive for the target OS/arch/libc (iOS: device or simulator), verifies **SHA-256**, caches it in the hook's shared output directory, and emits a `CodeAsset` with `DynamicLoadingBundled` | Flutter apps, desktop, servers wanting zero setup |
| `system` | Emits a `CodeAsset` with `DynamicLoadingSystem` (`libvips.so.42`, `libvips.42.dylib`, `libvips-42.dll`). Nothing is downloaded. Not available on iOS/Android. | Servers with distro libvips; users needing extra formats from their own build |
| `none` | Emits no asset. FFI is unavailable, so `auto` falls back to CLI. | CLI-only deployments (e.g. Pixtronaut's worker); air-gapped builds without a mirror |

Hook rules:

- Downloads come only from the package's own GitHub release URL, pinned per package version in `lib/src/native/artifacts.dart` (URL + SHA-256 per target), or from `libvips_archive_dir`. A checksum mismatch fails the build.
- The hook declares no dependencies on the network beyond that. Offline builds work once the cache is warm or with a mirror.
- An unsupported target in `bundled` mode emits no asset and prints a warning, and `auto` falls back to CLI or reports clearly at runtime. The build doesn't fail, because a pure-CLI use may still be intended.
- **L0 must verify:** user-define syntax and availability for the minimum SDK, hook caching across builds, Flutter iOS framework wrapping of the dylib, and Android packaging per ABI.

## 4.2 Targets and artifacts

| Target | Artifact | Toolchain / baseline |
|--------|----------|----------------------|
| linux-x64, linux-arm64 (glibc) | `libvips.so` | glibc ≥ 2.28 (manylinux_2_28-style) |
| linux-x64, linux-arm64 (musl) | `libvips.so` | Alpine 3.20+ |
| macos-arm64, macos-x64 | `libvips.dylib` | macOS 11+ |
| windows-x64 | `libvips.dll` | llvm-mingw, MSVC-compatible ABI |
| ios-arm64 (device), ios-arm64/x64 (simulator) | `libvips.dylib` (Flutter wraps it in a framework) | iOS 13+ |
| android-arm64-v8a, android-x86_64 | `libvips.so` | NDK r27+, minSdk 24, linked with **16 KB page alignment** (`-Wl,-z,max-page-size=16384`), as required for new Play Store uploads |

**One self-contained library per target.** libvips and all its dependencies
are linked **statically into a single shared library**. Only libvips/GObject
symbols used by the bindings are exported (version script /
`-fvisibility=hidden`). This prevents clashes with other native code in the
same app (other plugins bundling libjpeg/libpng/libwebp, or the Flutter
engine's own copies).

**Size budget:** ≤ 8 MB uncompressed per mobile ABI and ≤ 12 MB for desktop
and server targets with the default format set. Measured in L3/L4 and
recorded here.

## 4.3 What the default build contains

| Component | Purpose | Licence |
|-----------|---------|---------|
| libvips (pinned 8.16.x/8.17.x) | Engine | LGPL-2.1-or-later |
| glib / gobject (minimal) + libffi | libvips runtime | LGPL-2.1+ / MIT |
| libjpeg-turbo | JPEG load/save | IJG/BSD-3 |
| libspng + zlib-ng | PNG load/save | BSD-2 / zlib |
| libwebp (+ sharpyuv) | WebP load/save, animation | BSD-3 |
| (built-in) libnsgif | GIF load | MIT |
| lcms2 | ICC colour conversion | MIT |
| libexif | Orientation and EXIF parsing | LGPL-2.1+ |
| expat | XMP parsing | MIT |
| highway | SIMD kernels | Apache-2.0 / BSD-3 |
| quantizr *(if viable)* | PNG palette quantisation | MIT |

Explicitly **excluded**: ImageMagick, poppler (PDF), librsvg (SVG),
OpenEXR, FITS/matio/OpenSlide, libimagequant (GPL-3), fftw (GPL). These
reduce the attack surface and keep the licensing simple. GIF **saving** (cgif)
is excluded in v1 because there's no GIF encoder.

**Extended variant (v1.x, opt-in via `libvips_variant: extended`):** adds
libheif + libde265/x265 or dav1d/aom for HEIC/AVIF. HEVC has patent
implications, so it's never part of the default.

## 4.4 Artifact build pipeline (in the `image_transform` repo)

```
native/
├── versions.json          # pinned versions + source URLs + SHA-256 of every dependency tarball
├── build.sh               # one entry point: build.sh <target>
├── cross/                 # meson cross files: android-*, ios-*, linux-*-musl, windows-x64
├── patches/
└── smoke/                 # tiny C program: load fixture → thumbnail → webpsave, run on host targets
```

- Based on the proven build scripts of the `sharp-libvips` project (Apache-2.0), which already cover Linux (glibc/musl), macOS and Windows, and extended with iOS and Android cross builds.
- A GitHub Actions matrix builds every target on tag `native-v<libvips>-r<n>`. It runs the smoke test where the target can execute (Linux x64/arm64 runners, macOS, Windows; Android/iOS via emulator/simulator in L4), then uploads `image_transform-libvips-<version>-<target>.tar.gz` + `SHA256SUMS` + `THIRD_PARTY_NOTICES` to a GitHub release.
- `tool/update_artifacts.dart` regenerates `lib/src/native/artifacts.dart` from `SHA256SUMS`. A package release always pins exactly one native release.
- Reproducibility: pinned toolchains and dependency checksums, with `SOURCE_DATE_EPOCH` set.

## 4.5 Licensing obligations (documented in the README)

- The package's Dart code is BSD-3-Clause.
- The bundled native library contains LGPL-2.1+ code (libvips, glib, libexif). It's shipped as a **separate dynamic library**, which users can replace (e.g. `system` mode, or by swapping the file), and the exact sources and build scripts are public in the repo. That's the standard way to meet LGPL obligations for dynamic linking.
- `THIRD_PARTY_NOTICES` ships inside every artifact. The README explains how Flutter apps should surface it (e.g. via `LicenseRegistry`, with a helper `registerImageTransformLicenses()` provided).
- App Store distribution of LGPL dynamic libraries is common practice, but the README advises teams to confirm with their own legal counsel. We don't give legal advice.
