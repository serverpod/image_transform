/// Downloads, verifies and caches prebuilt libvips for the build hook.
library;

// Internal to the build hook and the release tools.
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'native_manifest.dart';

/// Thrown when the library can't be obtained or fails verification.
class LibraryFetchException implements Exception {
  LibraryFetchException(this.message);

  final String message;

  @override
  String toString() => 'image_transform: $message';
}

/// A downloaded file didn't match the manifest. Always fatal: it means a
/// tampered mirror or a broken release, not a flaky network.
final class LibraryChecksumException extends LibraryFetchException {
  LibraryChecksumException(super.message);
}

/// Fetches one target's library into [cacheDirectory].
final class LibraryFetcher {
  LibraryFetcher({
    required this.cacheDirectory,
    required this.baseUrl,
    this.log = _noLog,
    this.retries = 3,
  });

  final Directory cacheDirectory;
  final Uri baseUrl;
  final void Function(String message) log;
  final int retries;

  static void _noLog(String _) {}

  /// Returns a verified local copy of [entry], downloading it if needed.
  Future<File> fetch(ManifestEntry entry) async {
    await cacheDirectory.create(recursive: true);
    final file = File(
      '${cacheDirectory.path}${Platform.pathSeparator}${entry.file}',
    );
    final marker = File('${file.path}.sha256');
    if (await file.exists() &&
        await marker.exists() &&
        (await marker.readAsString()).trim() == entry.sha256 &&
        await file.length() == entry.size) {
      return file;
    }

    final url = baseUrl.resolve(entry.asset);
    Object? lastError;
    for (var attempt = 1; attempt <= retries; attempt++) {
      try {
        log('downloading $url (attempt $attempt)');
        await _download(url, entry, file);
        await marker.writeAsString(entry.sha256);
        return file;
      } on LibraryFetchException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt < retries) {
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
        }
      }
    }
    throw LibraryFetchException('could not download $url: $lastError');
  }

  Future<void> _download(Uri url, ManifestEntry entry, File target) async {
    final client = HttpClient()
      ..findProxy = HttpClient.findProxyFromEnvironment;
    final part = File('${target.path}.$pid.part');
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      final sink = part.openWrite();
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      var size = 0;
      final stream = url.path.endsWith('.gz')
          ? response.transform(gzip.decoder)
          : response;
      await for (final chunk in stream) {
        size += chunk.length;
        hasher.add(chunk);
        sink.add(chunk);
      }
      hasher.close();
      await sink.close();
      final hash = digest.value.toString();
      if (hash != entry.sha256 || size != entry.size) {
        throw LibraryChecksumException(
          'checksum mismatch for $url: expected ${entry.sha256} '
          '(${entry.size} bytes), got $hash ($size bytes)',
        );
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
    } finally {
      client.close(force: true);
      if (await part.exists()) {
        try {
          await part.delete();
        } on FileSystemException {
          // Best effort.
        }
      }
    }
  }
}

/// SHA-256 of [file] as lowercase hex.
Future<String> sha256OfFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
