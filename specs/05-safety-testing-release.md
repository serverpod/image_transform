# 5. Safety, testing and release

## 5.1 Untrusted-input posture

The package must be safe to point at arbitrary user uploads with **default
settings**:

| Layer | Default |
|-------|---------|
| Formats | Allow-list {jpeg, png, webp, gif}, detected by content |
| Compiled-in loaders | Only the default build's set ([04 §4.3](04-native-libraries.md#43-what-the-default-build-contains)); no SVG/PDF/ImageMagick |
| libvips blocks | `vips_block_untrusted_set`, plus non-allowed loaders blocked ([03 §3.1](03-backends.md#31-ffi-backend)) |
| Limits | `SourceLimits.defaults` checked from the header, before decode |
| Decoder strictness | `FailOn.error` |
| Metadata | Stripped (GPS included) |
| Option injection | Impossible by construction: only numbers, booleans and enums reach libvips options |
| Isolation | Not by default (FFI). The docs recommend the **CLI backend** for servers handling untrusted input at scale, since it gives crash containment and hard timeouts. |

## 5.2 Test matrix

| Suite | What | Runs on |
|-------|------|---------|
| Unit | Geometry tables (orientations, extreme aspects, clamping, upscale), planning, option formatting, CLI argument building, `vipsheader` parsing, limit checks, API validation | Any (no libvips) |
| **Conformance** | One declarative case list (`test/conformance/cases.yaml`: fixture × outputs × options → expected dims/frames/format/alpha/metadata presence) run through **every available backend** | Linux x64/arm64, macOS arm64, Windows x64 (FFI + CLI); iOS simulator, Android emulator (FFI, via an `integration_test` in `example/flutter_app`) |
| Hook | Bundled/system/none modes, checksum mismatch fails, offline mirror, unsupported target warning | Linux, macOS, Windows |
| Memory | 10 000 transforms in a loop; RSS must plateau (no leaked GObjects/blobs); finalizer safety net counted | Linux, macOS |
| Concurrency | Isolate pool saturation, cancellation, `close()` mid-queue, many transformers per process | Linux, macOS |
| Fuzz (weekly) | Malformed-image corpora (OSS-Fuzz corpora for libjpeg-turbo, libspng and libwebp, plus generated truncations) through FFI and CLI. Any crash or hang is a release blocker and is reported upstream. | Linux x64 |
| Benchmarks | Throughput and peak memory vs `package:image` (pure Dart) and vs the CLI backend; regressions > 15% flagged | Linux x64, Android arm64 |

**Fixtures:** EXIF orientations 1–8; CMYK JPEG; Display P3 JPEG; a GPS-tagged
JPEG; progressive JPEG; RGBA, 16-bit, palette and 1×1 PNGs; lossless and
animated WebP; animated and single-frame GIF; a PNG decompression bomb;
truncated JPEG; non-images (PDF, SVG, TIFF, HEIC) → `UnsupportedFormatException`.

## 5.3 Versioning and release

- Semver for the Dart API. Each release pins one native artifact release; `BackendInfo.nativeVersion` reports it.
- Native updates (libvips or dependency security fixes) ship as **patch** releases when behaviour is unchanged, and as minor releases otherwise.
- Release gates: all suites green, pub score 160/160, dartdoc on all public API, CHANGELOG entry, `THIRD_PARTY_NOTICES` regenerated.
- Published by GitHub Actions (`.github/workflows/publish.yml`, OIDC automated publishing) under the **serverpod.dev** verified publisher from tags `v<x.y.z>`. The **first** version is published by hand (`dart pub publish`); automated publishing is then enabled on pub.dev for this repository with tag pattern `v{{version}}`. Native releases (`native-v…`) are published first.
- CI gates (`.github/workflows/ci.yml`, every push and PR):
  - `dart format`, `dart analyze --fatal-infos`, `dart pub publish --dry-run`, and the pub.dev score with pana (any lost point fails);
  - unit tests on the minimum SDK (3.12.2) and on stable;
  - analysis and tests with the runtime dependencies at their lower bounds;
  - CLI conformance on macOS (Homebrew libvips), plus a non-blocking Ubuntu 8.15 job;
  - FFI conformance on Linux x64/arm64, macOS arm64/x64 and Windows x64/arm64;
  - an FFI run that downloads the library through the build hook;
  - running the example.
- Security fixes in bundled dependencies: a watch workflow (OSV/GitHub advisories on `native/versions.json`) opens an issue; the target is a patch release within 7 days for critical CVEs.

## 5.4 Documentation

- README: what it is, the platform/format matrix, a 3-line quick start, Flutter and server examples, backends and when to choose CLI, hook modes, limits and safety, licensing, FAQ (binary size, web, AVIF/HEIC).
- `example/`: `cli.dart` (batch-resize a folder) and `flutter_app/` (pick a photo → see sizes and outputs → share), which is also the integration-test host.
- Dartdoc on every public member, with defaults stated.

## 5.5 Milestones

| # | Milestone | Done when |
|---|-----------|-----------|
| **L0** | Spikes | (a) libvips CLI behaviours: `fail_on` pass-through, multi-page `thumbnail --crop`, `keep=none`, `vipsheader` fields, on libvips 8.16; (b) FFI operation-API binding prototype on macOS with Homebrew libvips (`system` mode): probe + thumbnail + webpsave; (c) build-hook prototype: download + checksum + `CodeAsset` for macOS and Linux; check `user_defines`; (d) cross-compile libvips for Android arm64 and iOS arm64 and load them in a Flutter test app. The results are written back into this spec. |
| **L1** | Core API + **CLI backend** | The full public API, planning, limits, the CLI backend, and the conformance suite on Linux/macOS. **This is what Pixtronaut's worker needs.** |
| **L2** ✅ | FFI backend | FFI backend through the generic operation API on an isolate pool, passing the shared conformance suite (40 tests + 5 FFI-specific: auto selection, isolate spread, non-blocking caller, flat memory over 350 calls, close). |
| **L3** ✅ | Bundled artifacts: desktop/server | Repackaged sharp-libvips (libvips 8.18.7) for macOS, Linux (glibc + musl) and Windows, x64 + arm64, as the `native-v0.1.0` GitHub release; build hook downloads and verifies them; `bundled` is the default; per-OS smoke tests in `native.yml`. |
| **L4** | Mobile + own builds | Build libvips ourselves (meson cross builds based on sharp-libvips' recipes) with the minimal loader set, for iOS and Android (16 KB pages) and optionally replacing the desktop builds; Flutter example app; integration tests on simulator/emulator; `LicenseRegistry` helper. |
| **L5** | 1.0 | Docs, benchmarks, a fuzzing baseline, the licence helper, and publication on pub.dev. |

Pixtronaut's worker uses the CLI backend (process isolation for untrusted
uploads); the `pixtronaut` package's local fallback uses `auto`, i.e. the FFI
backend with the bundled libvips, so developers need nothing installed.
