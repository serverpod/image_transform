/// Raw bindings to the libvips/GObject C API used by the FFI backend.
///
/// Only non-variadic functions are bound (specs/03 §3.1): operations are
/// built with the generic operation API, scalar arguments are set with
/// `vips_object_set_from_string`, and images/blobs travel in GValues.
///
/// The library comes from this package's build hook as the code asset
/// `package:image_transform/src/ffi/libvips.dart`.
@DefaultAsset('package:image_transform/src/ffi/libvips.dart')
@internal
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

// ignore_for_file: public_member_api_docs, non_constant_identifier_names

typedef GType = Size;

/// sizeof(GValue) on 64-bit platforms.
const gValueSize = 24;

// -------------------------------------------------------------- lifecycle

@Native<Int Function(Pointer<Utf8>)>()
external int vips_init(Pointer<Utf8> argv0);

@Native<Int Function(Int)>()
external int vips_version(int flag);

@Native<Pointer<Utf8> Function()>()
external Pointer<Utf8> vips_error_buffer();

@Native<Void Function()>()
external void vips_error_clear();

@Native<Void Function(Int)>()
external void vips_cache_set_max(int max);

@Native<Void Function(Int)>()
external void vips_concurrency_set(int concurrency);

@Native<Void Function(Int)>()
external void vips_block_untrusted_set(int state);

@Native<Void Function(Pointer<Utf8>, Int)>()
external void vips_operation_block_set(Pointer<Utf8> name, int state);

// ------------------------------------------------------------- operations

@Native<Pointer<Void> Function(Pointer<Utf8>)>()
external Pointer<Void> vips_operation_new(Pointer<Utf8> name);

@Native<Pointer<Void> Function(Pointer<Void>)>()
external Pointer<Void> vips_cache_operation_build(Pointer<Void> operation);

@Native<Void Function(Pointer<Void>)>()
external void vips_object_unref_outputs(Pointer<Void> object);

@Native<Int Function(Pointer<Void>, Pointer<Utf8>)>()
external int vips_object_set_from_string(
  Pointer<Void> object,
  Pointer<Utf8> string,
);

// ---------------------------------------------------------------- GObject

@Native<Void Function(Pointer<Void>)>()
external void g_object_unref(Pointer<Void> object);

@Native<Pointer<Void> Function(Pointer<Void>)>()
external Pointer<Void> g_object_ref(Pointer<Void> object);

@Native<Void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>)>()
external void g_object_set_property(
  Pointer<Void> object,
  Pointer<Utf8> name,
  Pointer<Void> value,
);

@Native<Void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>)>()
external void g_object_get_property(
  Pointer<Void> object,
  Pointer<Utf8> name,
  Pointer<Void> value,
);

@Native<Pointer<Void> Function(Pointer<Void>, GType)>()
external Pointer<Void> g_value_init(Pointer<Void> value, int type);

@Native<Void Function(Pointer<Void>)>()
external void g_value_unset(Pointer<Void> value);

@Native<Void Function(Pointer<Void>, Pointer<Void>)>()
external void g_value_set_object(Pointer<Void> value, Pointer<Void> object);

@Native<Pointer<Void> Function(Pointer<Void>)>()
external Pointer<Void> g_value_get_object(Pointer<Void> value);

@Native<Void Function(Pointer<Void>, Pointer<Void>)>()
external void g_value_set_boxed(Pointer<Void> value, Pointer<Void> boxed);

@Native<Pointer<Void> Function(Pointer<Void>)>()
external Pointer<Void> g_value_get_boxed(Pointer<Void> value);

@Native<Void Function(Pointer<Void>, Pointer<Utf8>)>()
external void g_value_set_string(Pointer<Void> value, Pointer<Utf8> string);

@Native<GType Function(Pointer<Utf8>)>()
external int g_type_from_name(Pointer<Utf8> name);

@Native<Void Function(Pointer<Void>)>()
external void g_free(Pointer<Void> memory);

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>()
external Pointer<Utf8> g_getenv(Pointer<Utf8> name);

@Native<Int Function(Pointer<Utf8>, Pointer<Utf8>, Int)>()
external int g_setenv(Pointer<Utf8> name, Pointer<Utf8> value, int overwrite);

@Native<Void Function(Pointer<Pointer<Utf8>>)>()
external void g_strfreev(Pointer<Pointer<Utf8>> strings);

// ------------------------------------------------------------ vips types

@Native<GType Function()>()
external int vips_image_get_type();

@Native<GType Function()>()
external int vips_blob_get_type();

@Native<GType Function()>()
external int vips_array_image_get_type();

@Native<GType Function()>()
external int vips_array_double_get_type();

@Native<Pointer<Void> Function(Pointer<Void>, Size)>()
external Pointer<Void> vips_blob_copy(Pointer<Void> data, int length);

@Native<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>()
external Pointer<Void> vips_blob_get(Pointer<Void> blob, Pointer<Size> length);

@Native<Void Function(Pointer<Void>)>()
external void vips_area_unref(Pointer<Void> area);

@Native<Pointer<Void> Function(Pointer<Pointer<Void>>, Int)>()
external Pointer<Void> vips_array_image_new(
  Pointer<Pointer<Void>> images,
  int n,
);

@Native<Pointer<Double> Function(Pointer<Void>, Pointer<Int>)>()
external Pointer<Double> vips_array_double_get(
  Pointer<Void> array,
  Pointer<Int> n,
);

// ----------------------------------------------------------------- images

@Native<Pointer<Utf8> Function(Pointer<Void>, Size)>()
external Pointer<Utf8> vips_foreign_find_load_buffer(
  Pointer<Void> data,
  int size,
);

@Native<Pointer<Pointer<Utf8>> Function(Pointer<Void>)>()
external Pointer<Pointer<Utf8>> vips_image_get_fields(Pointer<Void> image);

@Native<Int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>()
external int vips_image_get_as_string(
  Pointer<Void> image,
  Pointer<Utf8> name,
  Pointer<Pointer<Utf8>> out,
);

@Native<Int Function(Pointer<Void>)>()
external int vips_image_get_width(Pointer<Void> image);

@Native<Int Function(Pointer<Void>)>()
external int vips_image_get_height(Pointer<Void> image);

@Native<Int Function(Pointer<Void>)>()
external int vips_image_get_page_height(Pointer<Void> image);

@Native<Int Function(Pointer<Void>)>()
external int vips_image_get_n_pages(Pointer<Void> image);

/// Address of `g_object_unref`, for NativeFinalizers.
Pointer<NativeFinalizerFunction> get gObjectUnrefAddress =>
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      g_object_unref,
    ).cast();

/// Address of `vips_area_unref`, for NativeFinalizers.
Pointer<NativeFinalizerFunction> get vipsAreaUnrefAddress =>
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      vips_area_unref,
    ).cast();
