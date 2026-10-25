@Tags(['ffi'])
library;

import 'package:image_transform/image_transform.dart';
import 'package:test/test.dart';

import 'support/conformance.dart';

void main() => runConformance(BackendPreference.ffi, BackendKind.ffi);
