@Tags(['ffi'])
library;

import 'dart:async';
import 'dart:io';

import 'package:image_transform/image_transform.dart';
import 'package:test/test.dart';

const _fixtures = 'test/fixtures';

void main() {
  test('auto prefers the FFI backend when the native library loads', () async {
    final t = await ImageTransformer.create();
    try {
      expect(t.info.kind, BackendKind.ffi);
      expect(t.info.reasons.join('\n'), contains('ffi: using'));
    } finally {
      await t.close();
    }
  });

  test('concurrent calls are spread over the worker isolates', () async {
    final t = await ImageTransformer.create(
      const TransformerConfig(backend: BackendPreference.ffi, workers: 3),
    );
    try {
      final bytes = File('$_fixtures/landscape.jpg').readAsBytesSync();
      final results = await Future.wait([
        for (var i = 1; i <= 24; i++)
          t.transform(ImageInput.bytes(bytes), [
            ImageOutput(
              name: 'a',
              resize: Resize.fit(width: 10 * i),
            ),
          ]),
      ]);
      expect(
        [for (final r in results) r['a'].width],
        [for (var i = 1; i <= 24; i++) 10 * i],
      );
    } finally {
      await t.close();
    }
  });

  test('the calling isolate keeps running while libvips works', () async {
    final t = await ImageTransformer.create(
      const TransformerConfig(backend: BackendPreference.ffi, workers: 1),
    );
    try {
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      await t.transform(ImageInput.file('$_fixtures/landscape.jpg'), [
        for (final w in [50, 100, 150, 200, 250, 300])
          ImageOutput(
            name: 'w$w',
            resize: Resize.fit(width: w),
            encode: const Encode.webp(effort: 6),
          ),
      ]);
      timer.cancel();
      expect(ticks, greaterThan(0));
    } finally {
      await t.close();
    }
  });

  test('memory stays flat over many transforms', () async {
    final t = await ImageTransformer.create(
      const TransformerConfig(backend: BackendPreference.ffi, workers: 2),
    );
    try {
      final bytes = File('$_fixtures/landscape.jpg').readAsBytesSync();
      Future<void> batch(int n) => Future.wait([
        for (var i = 0; i < n; i++)
          t.transform(ImageInput.bytes(bytes), const [
            ImageOutput(name: 'a', resize: Resize.fit(width: 64)),
            ImageOutput(name: 'b', resize: Resize.cover(32, 32)),
          ]),
      ]);
      await batch(50); // warm up allocators and code paths
      final before = ProcessInfo.currentRss;
      for (var i = 0; i < 6; i++) {
        await batch(50);
      }
      final growth = ProcessInfo.currentRss - before;
      // 300 calls with leaked images/blobs would grow by far more than this.
      expect(growth, lessThan(64 * 1024 * 1024), reason: '$growth bytes');
    } finally {
      await t.close();
    }
  });

  test('close() stops the workers and rejects later calls', () async {
    final t = await ImageTransformer.create(
      const TransformerConfig(backend: BackendPreference.ffi),
    );
    await t.close();
    expect(
      () => t.probe(ImageInput.file('$_fixtures/tiny.png')),
      throwsStateError,
    );
  });
}
