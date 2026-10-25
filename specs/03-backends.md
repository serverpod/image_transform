# 3. Backends

| | FFI backend | CLI backend |
|-|-------------|-------------|
| How | libvips loaded in-process via `dart:ffi` (native assets) | Spawns `vips` / `vipsheader` child processes |
| Platforms | macOS, Linux (glibc, musl), Windows, x64 and arm64 (iOS/Android: later milestone L4) | Linux, macOS, Windows (needs `dart:io` `Process`) |
| libvips source | Bundled prebuilt (default) or system library ([04](04-native-libraries.md)) | `vips` on `PATH` or configured paths (e.g. distro `libvips-tools`, Homebrew) |
| Isolation | Same process. A libvips crash kills the app/server. | Separate process per operation. Crashes and hangs are contained. |
| Timeouts | Cooperative (between steps; `vips_image_set_kill` in a later minor) | Hard: SIGKILL after `processTimeout` |
| Inputs/outputs | In memory (files are read into memory) | Files (bytes are spooled to temp files) |
| Overhead | Lowest (no process spawn, no temp files) | ~5–20 ms per process plus disk I/O |
| Best for | Flutter apps, desktop tools, trusted server input | Servers processing **untrusted** uploads; environments without a prebuilt for the target |

## 3.1 FFI backend

### Binding strategy

Bind libvips through its **generic operation API**, the way pyvips and
ruby-vips do, rather than the variadic convenience functions
(`vips_thumbnail(…, NULL)`). This avoids variadic calls (whose ABI differs on
arm64 Apple platforms) and gives one uniform code path for every operation:

```
op = vips_operation_new("thumbnail_buffer")
g_object_set_property(op, "buffer", <GValue VipsBlob>)        // images, blobs, image arrays, strings
vips_object_set_from_string(op, "width=640,size=down,…")      // every scalar option
op2 = vips_cache_operation_build(op)                           // runs the operation
g_object_get_property(op2, "out", <GValue VipsImage>)         // read outputs
vips_object_unref_outputs(op2); g_object_unref(op2); g_object_unref(op)
```

- **Implemented (L2)** in `lib/src/ffi/`: `libvips.dart` (hand-written `@Native` bindings with `@DefaultAsset('package:image_transform/src/ffi/libvips.dart')`; only non-variadic functions), `vips.dart` (operations, GValues, header fields), `render.dart` (the render steps) and `ffi_backend.dart` (isolate pool).
- **Scalar options go through `vips_object_set_from_string`** with the *same* option strings the CLI backend builds (`CliArgs.saveOptions`, thumbnail options), so both backends share one source of truth for option syntax. Only library-generated, validated values reach those strings. Images, blobs, image arrays (`arrayjoin`) and strings (`option_string`) travel as GValues.
- **Header fields** come from `vips_image_get_fields` + `vips_image_get_as_string`; enum values are normalised to the nicknames `vipsheader` prints (`((VipsInterpretation) VIPS_INTERPRETATION_sRGB)` → `srgb`), so both backends share `imageInfoFromHeader`.
- **Ownership:** sources are `VipsBlob`s (copied once per call into the worker that owns them); images and blobs are released explicitly in `finally` blocks, with a `NativeFinalizer` (`g_object_unref` / `vips_area_unref`) as a safety net. Output blobs are copied into Dart memory before the operation's outputs are released.
- **Operations used:** `thumbnail_buffer` (fit, cover with libvips crops, the resize step of manual crops, placeholder), `extract_area` (focal crops and per-frame crops of animated images), `arrayjoin` (rejoining cropped frames), `webpsave_buffer` / `jpegsave_buffer` / `pngsave_buffer`, and `*load_buffer` with `access=sequential` for the header probe and for measuring outputs.
- **Verified (L2):** `thumbnail_buffer` does not forward its own `fail_on` to the loader, so `fail_on=…` is also passed in the loader `option_string`. Because libvips decodes lazily, a truncated JPEG then fails during the *save* step; decode-looking errors from any step are reported as `DecodeException`, like the CLI backend.

### Process-global libvips setup (once per process, guarded)

libvips setup is **not** safe to run on several threads at once (verified: concurrent `vips_init` + `vips_operation_block_set` from two isolates crashes). So `FfiBackend.create` runs it on the creating isolate before any worker starts, under a **process-wide lock** (an exclusively created `image_transform-<pid>.lock` file). The setup state (`init;<unblocked formats>`) is kept in the process environment (`g_setenv`) because isolate *groups* (e.g. parallel test suites) share libvips but not Dart statics; a second transformer therefore never re-blocks loaders another one unblocked.


| Call | Value | Why |
|------|-------|-----|
| `vips_init("image_transform")` | — | Idempotent, process-wide |
| `vips_cache_set_max(0)` | Disable the operation cache | Long-running processes don't grow memory; results aren't reused anyway |
| `vips_concurrency_set(n)` | `vipsThreads` or default | Threads per operation |
| `vips_block_untrusted_set(TRUE)` | — | Blocks loaders flagged as untrusted |
| `vips_operation_block_set("VipsForeignLoad", TRUE)`, then unblock the allowed loaders | jpeg/png/webp/gif loaders | Defence in depth beside the probe allow-list. Process-wide: the **union** of all transformers' `allowedFormats` stays unblocked. |

### Isolates

- libvips calls block, so the FFI backend runs them on a **pool of long-lived worker isolates**. Default size: 1 on iOS/Android, `max(1, cores ÷ 2)` elsewhere. libvips threads internally, so more isolates mostly add memory pressure.
- Each prepared source is pinned to the least-loaded worker; probe, render (one request per output) and placeholder calls for that source go to the same worker, which owns its `VipsBlob`. Bytes cross isolate boundaries as `TransferableTypedData` (zero-copy). Workers process one request at a time.
- Safe to use from Flutter's UI isolate; nothing blocks it. Works with iOS background tasks (no main-thread requirement).
- `close()` asks each worker to free its sources, then kills it. libvips itself stays initialised for the process lifetime.

### Cancellation and timeouts (FFI)

v1 checks the `CancellationToken` between steps (probe, each output,
placeholder). Remaining outputs become `OutputFailure(TransformCancelledException)`.
Interrupting a running libvips operation (`vips_image_set_kill` from the
coordinating isolate) is planned for a minor release.

## 3.2 CLI backend

- **Probe:** `vipsheader -a <file>`, parsed `name: value` lines (field names as in [02 §2.2](02-semantics.md#22-probe)).
- **Renders:** argument lists passed to `Process.start` (never a shell). Options go only in the libvips `[…]` filename-suffix syntax, built from validated numbers and booleans:

```
# fit
vips thumbnail <src>[<load>] <out>.<ext>[<save>] <W> --height <H> --size down|both --export-profile srgb --fail-on <level>
# cover, libvips crop (still images)
vips thumbnail <src>[<load>] <out>.<ext>[<save>] <boxW> --height <boxH> --crop centre|attention|entropy --size down|both --export-profile srgb --fail-on <level>
# cover, focal crop or animated input (two steps via a .v intermediate)
vips thumbnail <src>[<load>] <tmp>.v <resizedW> --height <resizedH> --size force --export-profile srgb --fail-on <level>
vips extract_area <tmp>.v <out>.<ext>[<save>] <left> <top> <boxW> <boxH>
```

  - `<load>`: `n=-1` (preserve animation) or `n=1` (first frame), **only for GIF/WebP**. Other loaders reject unknown options such as `n` (`jpegload: no property named 'n'`).
  - **L0 finding:** strictness must be passed as `thumbnail --fail-on <none|warning|error>`. A `fail_on=` *loader* option in the file name is silently ignored by `thumbnail`: a truncated JPEG still renders with exit 0.
  - **L0 finding:** when `--height` is omitted, `thumbnail` defaults it to the width (a square box). Width-only fits therefore pass `--height 10000000`, and height-only fits pass `W = 10000000`.
  - **L0 finding:** `--export-profile` is still accepted in 8.18, where the documented names are `--output-profile`/`--input-profile`, so the library keeps the 8.15-compatible spelling. `ColorPolicy.preserve` omits it.
  - `<save>`: encoder options from [02 §2.6](02-semantics.md#26-encoders) plus `keep=none|icc|all`. **L0 finding:** `keep=none` removes all `exif-*` fields; `keep=all` keeps them, with `orientation` reset to 1 after auto-rotation. JPEG saves add `background=255`, because the default flattens alpha onto black.
  - All file names are relative, library-generated names, and every process runs with the call's temp directory as its working directory. User paths, which may contain spaces or `[`/`,` option syntax, never reach libvips: file inputs are symlinked (or copied) to `source`.
- **Measure:** `vipsheader -a <out>` plus the file length. **L0 finding:** the field names are `width`, `height` (one page unless loaded with `n=-1`), `n-pages`, `page-height` (only with `n=-1`), `orientation`, `bands`, `interpretation` (`srgb`, `b-w`, `grey16`, `cmyk`, …), `vips-loader` and `icc-profile-data`. The first output line is a `file: summary` line and is skipped.
- **Environment:** `VIPS_BLOCK_UNTRUSTED=1` for every process that reads the source, plus `VIPS_CONCURRENCY=<vipsThreads>` and `CliConfig.environment`. **L0 finding:** `VIPS_BLOCK_UNTRUSTED` also blocks `vipsload` (`.v` files) and `svgload`, so steps that read only the library's own `.v` intermediates run without it. SVGs aren't recognised at all, which gives a second layer of rejection.
- **Timeouts:** each process is killed (SIGKILL, or `TerminateProcess` on Windows) after `processTimeout` → `TransformTimeoutException`.
- **Parallelism:** at most `workers` processes at once (default `max(1, cores ÷ 2)`).
- **Temp files:** a per-call directory under `tempDirectory`, deleted in `finally`. Bytes inputs are written there, and bytes outputs are read back.
- **Version:** `vips --version` must be ≥ **8.15** (needed for `keep=`). Otherwise → `BackendUnavailableException`.
- Argument builders (`CliArgs`) are `@internal` and pure, so tests can assert command lines without running libvips.

## 3.3 Backend parity

Both backends implement the same internal interface:

```dart
abstract interface class TransformBackend {
  Future<ImageInfo> probe(ImageInput input, TransformOptions options);
  Future<TransformResult> run(ImageInput input, List<PlannedOutput> outputs, PlannedPlaceholder? placeholder,
                              TransformOptions options, CancellationToken? cancel);
  Future<void> close();
}
```

Planning, validation, limits and result shaping live **above** this
interface, so they exist once. Conformance tests run every case through each
available backend and compare dimensions, frames, format, alpha and metadata
presence. Byte-identical output isn't required, but byte size within ±10% of
the other backend is asserted when both use the same libvips version.

## 3.4 Backend selection (`BackendPreference.auto`)

1. On web → `UnsupportedError`.
2. If the native library asset resolves and loads (bundled or system), and its version is ≥ 8.15 → **FFI**.
3. Otherwise, on Linux/macOS/Windows, if `vips --version` works and is ≥ 8.15 → **CLI**.
4. Otherwise → `BackendUnavailableException`, with one reason per attempt and a hint, e.g.: "no prebuilt libvips for linux-riscv64; install libvips-tools or set `hooks.user_defines.image_transform.libvips: system`".

`BackendPreference.ffi` / `.cli` force a backend and fail if it's unavailable.
`ImageTransformer.info` reports what was chosen and why.
