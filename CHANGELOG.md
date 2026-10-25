## 0.1.0

First release.

- `ImageTransformer`: one call that decodes once and writes any number of outputs, plus `probe`, `plan` and placeholders.
- Resizing: `Resize.fit` and `Resize.cover` with centre, attention, entropy and focal-point crops. Images are never upscaled unless asked.
- Encoding: WebP (including animated), JPEG and PNG.
- Defaults: EXIF orientation applied, sRGB conversion, metadata stripped (including GPS).
- Safety for untrusted input: format allow-list detected by content; pixel, frame and byte limits checked from the header before decoding; strict decoding; every other libvips loader blocked.
- Two backends with the same API:
  - **FFI** (default): libvips in-process, running on a pool of worker isolates. A build hook downloads a prebuilt, checksum-verified libvips 8.18.7 for macOS, Linux (glibc and musl) and Windows, x64 and arm64.
  - **CLI**: runs libvips ≥ 8.15 tools in child processes, with hard timeouts.
- Convenience functions `transformBytes` and `probeBytes`.
