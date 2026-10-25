# 2. Processing semantics

This chapter defines **what** every backend must do. [03](03-backends.md)
defines **how** the FFI and CLI backends do it. Both backends are tested
against the same conformance suite ([05 §5.2](05-safety-testing-release.md#52-test-matrix)).

## 2.1 Pipeline

```
input → detect loader → allow-list check → read header → limits check → for each output: plan → render → encode → write
                                                                     └→ placeholder (optional)
```

Planning (geometry) is pure Dart and identical for both backends. A backend
only executes a plan.

## 2.2 Probe

Loader detection runs first and reads only the magic bytes. Then the header is
read **without decoding pixels**. Fields:

| Field (libvips) | `ImageInfo` | Notes |
|-----------------|-------------|-------|
| loader nickname (`vips-loader`) | `format`, `loader` | Mapped: `jpegload*` → jpeg, `pngload*` → png, `webpload*` → webp, `gifload*` → gif. Anything else → `UnsupportedFormatException`. |
| `width`, `height` | `width`, `height` | For multi-page images, the height of **one** frame |
| `n-pages` | `frames` | Absent → 1 |
| `page-height` | — | Used for multi-frame geometry |
| `orientation` | `orientation`, `orientedWidth/Height` | Absent → 1. 5–8 swap width and height. |
| `bands`, `interpretation` | `hasAlpha`, `colorSpace` | Alpha if bands is 2/4 (or 5 for CMYK) |
| `icc-profile-data` present | `hasIccProfile` | |

## 2.3 Allow-list and limits

Checked after the probe and **before** any pixel decode:

| Check | Source | Error |
|-------|--------|-------|
| Format in `allowedFormats` (and compiled into the backend) | config | `UnsupportedFormatException` |
| Input size ≤ `maxInputBytes` | limits | `SourceLimitsException('maxInputBytes')`. Streams abort as soon as the limit is crossed. |
| `width × height` ≤ `maxPixels` | limits | `SourceLimitsException('maxPixels')` |
| `frames` ≤ `maxFrames` (only if animation is preserved) | limits | `SourceLimitsException('maxFrames')` |
| `width × height × frames` ≤ `maxAnimatedPixels` (only if preserved) | limits | `SourceLimitsException('maxAnimatedPixels')` |
| Any output dimension > 16383 for WebP or > 65500 for JPEG | encoder limits | `InvalidTransformException` (from `plan`) |

## 2.4 Geometry

Notation: `sw, sh` is the **oriented** source size, `rw, rh` is the requested
size, and `up` is the `upscale` flag.

**Fit**
- `scale = min(rw/sw if rw, rh/sh if rh)`. If `!up`, `scale = min(1, scale)`.
- Output is `max(1, round(sw·scale)) × max(1, round(sh·scale))`.
- `clamped = !up && unclampedScale > 1`.

**Cover**
- If `!up` and (`rw > sw` or `rh > sh`): shrink the box, keeping the aspect: `k = min(sw/rw, sh/rh)`, box = `max(1, floor(rw·k)) × max(1, floor(rh·k))`, and `clamped = true`. Otherwise the box is `rw × rh`.
- Resize scale `s = max(boxW/sw, boxH/sh)`. The resized size is `ceil(sw·s) × ceil(sh·s)`, and the overflow is cropped to the box.
- `centre` / `attention` / `entropy`: libvips' own crop.
- `focal(fx, fy)`: window `left = clamp(round(fx·resizedW − boxW/2), 0, resizedW − boxW)`, and the same for `top`.

**No resize** (`resize: null`): output = oriented source size.

`ImageTransformer.plan()` exposes these numbers, so a UI can lay out an image
before it's processed.

## 2.5 Orientation, colour and metadata

| Concern | Default | Options |
|---------|---------|---------|
| EXIF orientation | Applied (pixels rotated upright, orientation tag reset to 1) | `autoOrient: false` keeps the stored orientation and tag |
| Colour | **Convert to sRGB** (embedded profiles such as Display P3, Adobe RGB and CMYK are honoured on import; untagged images are assumed sRGB) | `ColorPolicy.preserve`: no conversion, and the ICC profile is kept |
| Metadata | **Strip all**: EXIF (incl. GPS), XMP, IPTC, ICC | `MetadataPolicy.icc` keeps the ICC profile, and `.all` keeps everything except the orientation tag (which becomes 1) |
| 16-bit input | Converted to 8-bit for JPEG/WebP output | PNG output keeps 16-bit only with `ColorPolicy.preserve` |
| Alpha | Preserved for WebP/PNG. Flattened onto white for JPEG. | `Encode.jpeg(background: …)` in a later minor release |

## 2.6 Encoders

| Encoder | Parameters (defaults) | libvips saver options |
|---------|-----------------------|-----------------------|
| WebP | `quality 80`, `lossless false`, `effort 4`, `smartSubsample true`, `alphaQuality 100` | `Q`, `lossless`, `effort`, `smart_subsample`, `alpha_q` |
| JPEG | `quality 82`, `progressive true`, `optimizeCoding true`, `subsampling auto` (4:2:0 for Q < 90, otherwise 4:4:4) | `Q`, `interlace`, `optimize_coding`, `subsample_mode` |
| PNG | `compression 6`, `palette false`, `colors 256` | `compression`, `palette`, `Q`/`bitdepth`. `palette: true` requires a quantiser in the build ([04 §4.3](04-native-libraries.md#43-what-the-default-build-contains)); otherwise → `EncodeException` |

Every encoder applies the metadata policy (`keep=` option). Option values
are always numbers, booleans or enums formatted by the library. User strings
never reach libvips option syntax.

## 2.7 Animation

| Input | `AnimationMode.preserve` | `AnimationMode.firstFrame` |
|-------|--------------------------|----------------------------|
| Animated GIF/WebP → WebP | Animated WebP; delays and loop count kept | Still image of frame 1 |
| Animated → JPEG/PNG | Frame 1 (formats can't animate); `frames: 1` | Frame 1 |
| `fit` | Every frame resized identically | — |
| `cover` with centre/attention/entropy | Every frame resized and cropped identically. Attention and entropy fall back to **centre** on animated input (see L0 finding below). | — |
| `cover` with `focal` | **Frame 1 only** in v1, documented (cropping a stacked multi-frame image needs per-frame handling) | Frame 1 |

**L0 finding (libvips 8.18.7, Homebrew):** `thumbnail --crop` is **not**
frame-aware. On a multi-page image loaded with `n=-1` it crops the whole stack
of frames down to a single frame. `--size force` *is* frame-aware: every page
is resized and `page-height` is updated. The library therefore does cover crops
on animated input itself:
1. resize with `--size force` to the cover size;
2. crop with `extract_area`. That's one call over the whole stack when only columns are cut; when rows are cut, it's one call per frame (to uncompressed TIFF, since libvips 8.15's `arrayjoin` segfaults on `.v` inputs) plus `arrayjoin`.
3. save with `page_height=<box height>`.

Delays and the loop count survive this path, including with `keep=none`.
Saliency/entropy crops have no per-frame equivalent in the CLI, so animated
inputs use centre crops.

## 2.8 Placeholder

- First frame. The longest edge is `size` px (8..64, default 24). Fit, never upscaled. Alpha kept for WebP/PNG.
- Encoded with `PlaceholderOptions.encode` (default WebP quality 50, effort 6), with metadata always stripped.
- `Placeholder.dataUri` gives `data:<mime>;base64,…`.
- Produced from the same decode as the outputs where the backend allows it.

## 2.9 Decoder strictness

`FailOn.error` (default) rejects truncated or corrupt input with
`DecodeException`. `FailOn.warning` is stricter, and `FailOn.none` renders
whatever can be decoded (grey regions in broken parts).

## 2.10 Result measurement

Reported `width`, `height`, `frames` and `byteLength` are **measured from the
encoded output**, not predicted. A mismatch with `plan()` greater than 1 px is
a bug and is covered by conformance tests.
