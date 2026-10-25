# 3. Backends

| | FFI backend | CLI backend |
|-|-------------|-------------|
| How | libvips loaded in-process via `dart:ffi` (native assets) | Spawns `vips` / `vipsheader` child processes |
| Platforms | Linux, macOS, Windows, iOS, Android | Linux, macOS, Windows (needs `dart:io` `Process`) |
| libvips source | Bundled prebuilt (default) or system library ([04](04-native-libraries.md)) | `vips` on `PATH` or configured paths (e.g. distro `libvips-tools`, Homebrew) |
| Isolation | Same process. A libvips crash kills the app/server. | Separate process per operation. Crashes and hangs are contained. |
| Timeouts | Cooperative (between steps; `vips_image_set_kill` in a later minor) | Hard: SIGKILL after `processTimeout` |
| Inputs/outputs | In memory (bytes) or files | Files (bytes are spooled to temp files) |
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
g_object_set_property(op, "buffer", <GValue VipsBlob>)   // per input/option
g_object_set_property(op, "width",  <GValue int>)
op2 = vips_cache_operation_build(op)                      // runs the operation
g_object_get_property(op2, "out", <GValue VipsImage>)    // read outputs
vips_object_unref_outputs(op2); g_object_unref(op2); g_object_unref(op)
```

- Bindings are generated with `package:ffigen` from a curated header (`native/include/image_transform_vips.h`) that declares only the symbols we use: init/shutdown, error buffer, version, concurrency/cache/block controls, operation API, GValue helpers, blob/area helpers, header getters (`vips_image_get_width`, `vips_image_get_typeof`, `vips_image_get_int`, …) and `vips_foreign_find_load(_buffer)`. External functions use `@Native` with the package's code-asset ID, so the same Dart code works for bundled and system libraries.
- A small internal Dart layer, `VipsOperation.call(name, {inputs})`, maps Dart values to GValues (int, double, bool, string, enum by nickname, `VipsImage`, `VipsBlob`, array of double/int).
- **Ownership:** every GObject the Dart side holds is wrapped in a `Finalizable` with a `NativeFinalizer(g_object_unref)` as a safety net, and is released explicitly in `finally` blocks for predictable memory. Output blobs are copied into Dart `Uint8List`s and then `vips_area_unref`'d.
- **Operations used:** `thumbnail` / `thumbnail_buffer` (fit, cover with libvips crops, shrink-on-load), `extract_area` (focal crops), `copy` (orientation-tag reset), `webpsave(_buffer)`, `jpegsave(_buffer)`, `pngsave(_buffer)`, and loader operations for the probe (`*load_buffer` with `access=sequential`, which reads the header lazily).

### Process-global libvips setup (once per process, guarded)

| Call | Value | Why |
|------|-------|-----|
| `vips_init("image_transform")` | — | Idempotent, process-wide |
| `vips_cache_set_max(0)` | Disable the operation cache | Long-running processes don't grow memory; results aren't reused anyway |
| `vips_concurrency_set(n)` | `vipsThreads` or default | Threads per operation |
| `vips_block_untrusted_set(TRUE)` | — | Blocks loaders flagged as untrusted |
| `vips_operation_block_set("VipsForeignLoad", TRUE)`, then unblock the allowed loaders | jpeg/png/webp/gif loaders | Defence in depth beside the probe allow-list. Process-wide: the **union** of all transformers' `allowedFormats` stays unblocked. |

### Isolates

- libvips calls block, so the FFI backend runs them on a **pool of long-lived worker isolates**. Default size: 1 on iOS/Android, `max(1, cores ÷ 2)` elsewhere. libvips threads internally, so more isolates mostly add memory pressure.
- Requests are queued FIFO and dispatched to idle isolates. Bytes cross isolate boundaries as `TransferableTypedData` (zero-copy).
- Safe to use from Flutter's UI isolate; nothing blocks it. Works with iOS background tasks (no main-thread requirement).
- `close()` drains the queue, then shuts the isolates down. libvips itself stays initialised for the process lifetime.

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
