/// Synchronous libvips helpers on top of the raw bindings. They block the
/// calling isolate, so the FFI backend only calls them from its worker
/// isolates (tests also use them to inspect outputs).
@internal
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../types.dart';
import 'libvips.dart';

// ignore_for_file: public_member_api_docs

/// libvips reported an error; [message] is the drained error buffer.
final class VipsError implements Exception {
  VipsError(this.message, {this.operation});

  /// The libvips error buffer (without the operation name, so it can be
  /// classified like CLI stderr).
  final String message;

  /// The operation that failed, if any.
  final String? operation;

  @override
  String toString() => 'VipsError(${operation ?? '-'}): $message';
}

/// Loader classes unblocked for each allowed format. All other loaders are
/// blocked process-wide (defence in depth beside the probe allow-list).
const _loaderClasses = {
  ImageFormat.jpeg: ['VipsForeignLoadJpeg'],
  ImageFormat.png: ['VipsForeignLoadPng', 'VipsForeignLoadSpng'],
  ImageFormat.webp: ['VipsForeignLoadWebp'],
  ImageFormat.gif: ['VipsForeignLoadNsgif', 'VipsForeignLoadGif'],
};

/// Process-wide record of the libvips setup (`init;<format>,…`). Kept in
/// the process environment because isolate groups (e.g. parallel test
/// suites) share libvips but not Dart statics.
const _stateVariable = 'IMAGE_TRANSFORM_VIPS_STATE';

/// Initialises libvips for this process and unblocks the loaders of
/// [allowedFormats] (the union over all callers). Safe to call from any
/// isolate, any number of times.
void initVips({int? threads, Set<ImageFormat> allowedFormats = const {}}) {
  _withProcessLock(() {
    using((arena) {
      final name = _stateVariable.toNativeUtf8(allocator: arena);
      final current = g_getenv(name);
      final state = current == nullptr ? null : current.toDartString();
      if (state == null) {
        if (vips_init('image_transform'.toNativeUtf8(allocator: arena)) != 0) {
          throw VipsError('vips_init failed: ${_drainError()}');
        }
        // Results are never reused, and an operation cache grows memory in
        // long-running servers.
        vips_cache_set_max(0);
        vips_block_untrusted_set(1);
        vips_operation_block_set(
          'VipsForeignLoad'.toNativeUtf8(allocator: arena),
          1,
        );
      }
      if (threads != null && threads > 0) vips_concurrency_set(threads);
      final unblocked = {
        for (final f in (state ?? 'init;').split(';').last.split(','))
          if (f.isNotEmpty) f,
      };
      for (final format in allowedFormats) {
        if (!unblocked.add(format.name)) continue;
        for (final loader in _loaderClasses[format] ?? const <String>[]) {
          vips_operation_block_set(loader.toNativeUtf8(allocator: arena), 0);
        }
      }
      g_setenv(
        name,
        'init;${(unblocked.toList()..sort()).join(',')}'.toNativeUtf8(
          allocator: arena,
        ),
        1,
      );
    });
  });
}

/// Runs [body] while holding a process-wide lock (an exclusively created
/// file named after the process), so libvips setup never runs on two
/// threads at once.
void _withProcessLock(void Function() body) {
  final lock = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'image_transform-$pid.lock',
  );
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    try {
      lock.createSync(exclusive: true);
      break;
    } on FileSystemException {
      if (DateTime.now().isAfter(deadline)) {
        // A stale lock from a crashed process with a recycled pid.
        try {
          lock.deleteSync();
        } on FileSystemException {
          // Someone else removed it.
        }
        continue;
      }
      sleep(const Duration(milliseconds: 2));
    }
  }
  try {
    body();
  } finally {
    try {
      lock.deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// `major.minor.patch` of the loaded libvips. Throws if the native library
/// isn't available.
String vipsVersionString() =>
    '${vips_version(0)}.${vips_version(1)}.${vips_version(2)}';

String _drainError() {
  final text = vips_error_buffer().toDartString();
  vips_error_clear();
  return text.trim();
}

// ------------------------------------------------------------ references

/// An owned reference to a `VipsImage`.
final class VipsImage implements Finalizable {
  VipsImage._(this.pointer) {
    _finalizer.attach(this, pointer, detach: this);
  }

  static final _finalizer = NativeFinalizer(gObjectUnrefAddress);

  final Pointer<Void> pointer;
  var _disposed = false;

  int get width => vips_image_get_width(pointer);
  int get height => vips_image_get_height(pointer);
  int get pageHeight => vips_image_get_page_height(pointer);
  int get pages => vips_image_get_n_pages(pointer);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    g_object_unref(pointer);
  }
}

/// An owned reference to a `VipsBlob` holding encoded image bytes.
final class VipsBlob implements Finalizable {
  VipsBlob._(this.pointer, this.length) {
    _finalizer.attach(this, pointer, detach: this);
  }

  /// Copies [bytes] into a new blob.
  factory VipsBlob.copy(Uint8List bytes) {
    final data = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      return VipsBlob._(
        vips_blob_copy(data.cast(), bytes.length),
        bytes.length,
      );
    } finally {
      malloc.free(data);
    }
  }

  static final _finalizer = NativeFinalizer(vipsAreaUnrefAddress);

  final Pointer<Void> pointer;
  final int length;
  var _disposed = false;

  /// Start of the blob's bytes.
  Pointer<Void> get data => using((arena) {
    final size = arena<Size>();
    return vips_blob_get(pointer, size);
  });

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    vips_area_unref(pointer);
  }
}

// ------------------------------------------------------------ operations

/// Argument values for [runOperation]: images, blobs, image arrays and
/// strings go through GValues; everything else belongs in `options`.
typedef VipsArgs = Map<String, Object>;

/// Builds and runs libvips operation [name]. [options] is a libvips option
/// string (`"width=100,size=down"`); only library-generated, validated
/// values may appear in it. [read] extracts outputs from the built
/// operation before its outputs are released.
T runOperation<T>(
  String name, {
  VipsArgs args = const {},
  String options = '',
  required T Function(Pointer<Void> operation, Arena arena) read,
}) => using((arena) {
  final op = vips_operation_new(name.toNativeUtf8(allocator: arena));
  if (op == nullptr) {
    throw VipsError('unknown operation: ${_drainError()}', operation: name);
  }
  Pointer<Void> built = nullptr;
  try {
    for (final MapEntry(:key, :value) in args.entries) {
      _setArg(op, key, value, arena);
    }
    if (options.isNotEmpty &&
        vips_object_set_from_string(
              op,
              options.toNativeUtf8(allocator: arena),
            ) !=
            0) {
      throw VipsError(_drainError(), operation: name);
    }
    built = vips_cache_operation_build(op);
    if (built == nullptr) throw VipsError(_drainError(), operation: name);
    return read(built, arena);
  } finally {
    if (built != nullptr) {
      vips_object_unref_outputs(built);
      g_object_unref(built);
    } else {
      vips_object_unref_outputs(op);
    }
    g_object_unref(op);
  }
});

int? _stringType;

void _setArg(Pointer<Void> op, String name, Object value, Arena arena) {
  final gvalue = arena<Uint8>(gValueSize).cast<Void>();
  switch (value) {
    case VipsImage(pointer: final image):
      g_value_init(gvalue, vips_image_get_type());
      g_value_set_object(gvalue, image);
    case VipsBlob(pointer: final blob):
      g_value_init(gvalue, vips_blob_get_type());
      g_value_set_boxed(gvalue, blob);
    case final List<VipsImage> images:
      final array = arena<Pointer<Void>>(images.length);
      for (var i = 0; i < images.length; i++) {
        array[i] = images[i].pointer;
      }
      final boxed = vips_array_image_new(array, images.length);
      g_value_init(gvalue, vips_array_image_get_type());
      g_value_set_boxed(gvalue, boxed);
      vips_area_unref(boxed);
    case final String text:
      _stringType ??= g_type_from_name(
        'gchararray'.toNativeUtf8(allocator: arena),
      );
      g_value_init(gvalue, _stringType!);
      g_value_set_string(gvalue, text.toNativeUtf8(allocator: arena));
    default:
      throw ArgumentError.value(value, name, 'Unsupported argument type');
  }
  g_object_set_property(op, name.toNativeUtf8(allocator: arena), gvalue);
  g_value_unset(gvalue);
}

/// Reads the image output [name] (default `out`) with a new reference.
VipsImage readImage(Pointer<Void> op, Arena arena, [String name = 'out']) {
  final gvalue = arena<Uint8>(gValueSize).cast<Void>();
  g_value_init(gvalue, vips_image_get_type());
  g_object_get_property(op, name.toNativeUtf8(allocator: arena), gvalue);
  final image = g_value_get_object(gvalue);
  g_object_ref(image);
  g_value_unset(gvalue);
  return VipsImage._(image);
}

/// Copies the blob output [name] (default `buffer`) into Dart memory.
Uint8List readBlob(Pointer<Void> op, Arena arena, [String name = 'buffer']) {
  final gvalue = arena<Uint8>(gValueSize).cast<Void>();
  g_value_init(gvalue, vips_blob_get_type());
  g_object_get_property(op, name.toNativeUtf8(allocator: arena), gvalue);
  final blob = g_value_get_boxed(gvalue);
  final size = arena<Size>();
  final data = vips_blob_get(blob, size).cast<Uint8>();
  final bytes = Uint8List.fromList(data.asTypedList(size.value));
  g_value_unset(gvalue);
  return bytes;
}

/// Copies the double-array output [name] into Dart memory.
List<double> readDoubles(Pointer<Void> op, Arena arena, String name) {
  final gvalue = arena<Uint8>(gValueSize).cast<Void>();
  g_value_init(gvalue, vips_array_double_get_type());
  g_object_get_property(op, name.toNativeUtf8(allocator: arena), gvalue);
  final array = g_value_get_boxed(gvalue);
  final n = arena<Int>();
  final values = vips_array_double_get(array, n);
  final result = [for (var i = 0; i < n.value; i++) values[i]];
  g_value_unset(gvalue);
  return result;
}

// ---------------------------------------------------------------- images

/// Nickname of the loader for [blob] (e.g. `jpegload_buffer`), or null if
/// no allowed loader recognises it.
String? findLoader(VipsBlob blob) {
  final name = vips_foreign_find_load_buffer(blob.data, blob.length);
  if (name == nullptr) {
    vips_error_clear();
    return null;
  }
  return name.toDartString();
}

/// Opens the header of [blob] with [loader] (pixels are decoded lazily).
VipsImage loadHeader(VipsBlob blob, String loader, {String options = ''}) =>
    runOperation(
      loader,
      args: {'buffer': blob},
      options: ['access=sequential', if (options.isNotEmpty) options].join(','),
      read: readImage,
    );

/// All header fields of [image] as `vipsheader -a` prints them.
Map<String, String> headerFields(VipsImage image) => using((arena) {
  final fields = vips_image_get_fields(image.pointer);
  final result = <String, String>{};
  try {
    for (var i = 0; fields[i] != nullptr; i++) {
      final name = fields[i];
      final out = arena<Pointer<Utf8>>();
      if (vips_image_get_as_string(image.pointer, name, out) == 0) {
        result[name.toDartString()] = _normalize(out.value.toDartString());
        g_free(out.value.cast());
      } else {
        vips_error_clear();
      }
    }
  } finally {
    g_strfreev(fields);
  }
  return result;
});

final _enumValue = RegExp(r'^\(\(\w+\) VIPS_[A-Z]+_(\w+)\)$');

/// `((VipsInterpretation) VIPS_INTERPRETATION_sRGB)` → `srgb`, matching the
/// nicknames `vipsheader` prints.
String _normalize(String value) {
  final m = _enumValue.firstMatch(value);
  if (m == null) return value;
  return m[1]!.toLowerCase().replaceAll('_', '-');
}

/// Header fields of encoded [bytes], or null if they aren't an image an
/// allowed loader can read. Used to measure outputs and by tests.
Map<String, String>? headerOfBytes(Uint8List bytes) {
  final blob = VipsBlob.copy(bytes);
  try {
    final loader = findLoader(blob);
    if (loader == null) return null;
    final image = loadHeader(blob, loader);
    try {
      return headerFields(image);
    } finally {
      image.dispose();
    }
  } finally {
    blob.dispose();
  }
}
