# 4. Native libraries

The FFI backend needs a libvips shared library for the **target** platform.
It's delivered through Dart's **build hooks** (native assets), so
`dart run`, `dart test`, `dart build cli` and `flutter build` pick it up
automatically, with no CocoaPods, Gradle or CMake glue.

**Decision (L3):** the prebuilt libraries are the
[sharp-libvips](https://github.com/lovell/sharp-libvips) builds, **repackaged
unchanged** and republished as a GitHub release of `serverpod/image_transform`
(the same pattern as `stockfish_dart`). Building libvips and its dependencies
ourselves is deferred to the mobile milestone (L4), which needs our own iOS
and Android builds anyway.

> **`dart compile exe` does not support packages with build hooks** (it fails
> with "use 'dart build' instead", even with `libvips: none`). Apps that
> depend on image_transform compile with `dart build cli` (as Serverpod's
> Dockerfile already does).

## 4.1 Hook modes and user-defines

```yaml
# in the consuming app's pubspec.yaml (all optional)
hooks:
  user_defines:
    image_transform:
      libvips: bundled            # bundled (default) | system | none
      library_dir: path/to/dir    # use your own libvips.{dylib,so,dll}
      download_base_url: https:// # mirror of the release assets
      allow_download: false       # never download
      require_native: true        # fail the build instead of warning
```

Resolution order (`hook/build.dart`):

| Step | Source | Notes |
|------|--------|-------|
| 1 | `libvips: none` | No asset; `auto` uses the CLI backend. For CLI-only deployments (e.g. Pixtronaut's worker). |
| 2 | `libvips: system` | `DynamicLoadingSystem`: `/opt/homebrew/lib/libvips.42.dylib` or `/usr/local/lib/…` if present, else `libvips.42.dylib`; `libvips.so.42`; `libvips-42.dll`. |
| 3 | `library_dir` | A directory with the target's `libvips.{dylib,so,dll}`. Offline / air-gapped builds and custom builds. |
| 4 | `native/out/<target>/` in this package | Local development (`dart run tool/fetch_sharp_libvips.dart`). |
| 5 | Download | From `native/manifest.json` (`baseUrl` + per-target asset), gunzipped, verified against SHA-256 and size, cached in the hook's shared output directory per release. |

Rules:

- **A failed download or an unsupported target never fails the build** (unless `require_native: true`): the hook logs a warning and emits no asset, and the FFI backend reports itself unavailable at runtime. Servers that never use the FFI backend (or build offline in CI) still build.
- **A checksum mismatch always fails the build** (tampered mirror or broken release).
- **musl:** build hooks don't receive libc information, so a Linux build is assumed to target the build host's libc (`/lib/ld-musl-*.so.1` present → `linux-musl-<arch>`). Cross-libc builds point `library_dir` at the right library.

## 4.2 Targets and artifacts

| Target | Library | sharp-libvips package | Smoke-tested in CI |
|--------|---------|-----------------------|--------------------|
| macos-arm64 | `libvips.dylib` | `darwin-arm64` | ✅ macos-15 |
| macos-x64 | `libvips.dylib` | `darwin-x64` | ✅ macos-15-intel |
| linux-x64 | `libvips.so` | `linux-x64` (glibc) | ✅ ubuntu-24.04 |
| linux-arm64 | `libvips.so` | `linux-arm64` (glibc) | ✅ ubuntu-24.04-arm |
| linux-musl-x64 | `libvips.so` | `linuxmusl-x64` | ❌ no Dart SDK for musl on runners |
| linux-musl-arm64 | `libvips.so` | `linuxmusl-arm64` | ❌ |
| windows-x64 | `libvips.dll` | `win32-x64` | ✅ windows-2025 |
| windows-arm64 | `libvips.dll` | `win32-arm64` | ✅ windows-11-arm |
| ios / android | — | — | L4 (own build) |

Each sharp-libvips package ships **one self-contained shared library**
(`libvips-cpp.<ver>.dylib`, `libvips-cpp.so.<ver>`, `libvips-42.dll`) with all
dependencies linked in and the full libvips/GObject C API exported; it only
depends on system libraries. We rename it to a stable `libvips.<ext>`.
Size: about 18 MB uncompressed, about 8 MB gzipped per target.

## 4.3 What the libraries contain

The sharp-libvips 1.3.4 build of **libvips 8.18.7** includes, among others:
mozjpeg, libpng, libwebp, cgif, libheif + aom (AVIF), librsvg, cairo/pango,
libtiff, lcms2, libexif, expat, libimagequant 2.4 (BSD), highway and glib.
Each release attaches `<target>-build-info.json` with the exact component
versions, and `THIRD_PARTY_NOTICES.md`.

The build contains **more loaders than image_transform allows** (SVG, TIFF,
HEIF, …). They are unreachable: the FFI backend blocks *every* loader with
`vips_operation_block_set("VipsForeignLoad", TRUE)` and unblocks only the
allowed formats (03 §3.1), on top of `vips_block_untrusted_set(TRUE)` and the
probe allow-list (verified by the conformance tests: TIFF and SVG are
rejected as `UnsupportedFormatException`). A smaller custom build (jpeg, png,
webp, gif only) is part of L4.

## 4.4 Release pipeline (`.github/workflows/native.yml`)

```
native/
├── sharp_libvips.json   # pinned sharp-libvips version, libvips version, npm tarball + SHA-512 integrity per platform
└── manifest.json        # what the hook downloads: release, baseUrl, per-target file/asset/sha256/size (written by the release job)
tool/
├── fetch_sharp_libvips.dart  # download + verify (SRI sha512) + extract → native/out/<target>/{libvips.*, build-info.json}
├── make_manifest.dart        # gzip assets + write manifest.json
└── third_party_notices.dart  # THIRD_PARTY_NOTICES.md from the build-info.json files
```

1. **fetch** (ubuntu): `dart run tool/fetch_sharp_libvips.dart --all`, uploads `native/out/`.
2. **smoke** (one runner per OS/arch): keeps only its target in `native/out/` and runs `dart test -t ffi` (the full FFI conformance suite, with FFI-based output inspection, so no libvips CLI is needed on the runner).
3. **release** (tags `native-v*`): `make_manifest.dart`; attaches the gzipped libraries, `<target>-build-info.json`, `manifest.json`, `THIRD_PARTY_NOTICES.md`, `LGPL-3.0.txt`, `GPL-3.0.txt` and the sharp-libvips source archive of the pinned tag; creates the GitHub release; commits `native/manifest.json` to `main`.

Bumping libvips: update `native/sharp_libvips.json` (version and integrity per platform), let CI pass, then tag the next `native-v*`. A package release pins exactly one native release through the committed manifest.

## 4.5 Licensing obligations (documented in the README)

- The package's Dart code is **BSD-3-Clause**.
- The prebuilt libraries are **LGPL-3.0-or-later** as a whole (libvips, glib and other LGPL components; the rest keep their own permissive licences, listed in `THIRD_PARTY_NOTICES.md`).
- They are separate dynamic libraries that users can replace (`library_dir`, `system`), and the corresponding source is the sharp-libvips build recipe of the pinned tag (attached to each release), which pins every upstream source tarball. That's the standard way to meet LGPL obligations for dynamic linking.
- Apps should surface `THIRD_PARTY_NOTICES.md`; a Flutter `LicenseRegistry` helper is planned for L4. We don't give legal advice; App Store distribution of LGPL libraries should be confirmed with counsel.
