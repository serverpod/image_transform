// Writes THIRD_PARTY_NOTICES.md for a native release from the build-info.json
// files in <dir>/<target>/.
//
//   dart run tool/third_party_notices.dart artifacts release-assets/THIRD_PARTY_NOTICES.md

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final dir = Directory(args.isEmpty ? 'native/out' : args.first);
  final target = File(args.length > 1 ? args[1] : 'THIRD_PARTY_NOTICES.md');
  final components = <String, Set<String>>{};
  final sources = <String>[];
  for (final info
      in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('build-info.json'))) {
    final json = jsonDecode(info.readAsStringSync()) as Map<String, Object?>;
    final source = json['source']! as Map<String, Object?>;
    sources.add(
      '| ${json['target']} | `${source['package']}@${source['version']}` | '
      '`${source['integrity']}` |',
    );
    final versions = (json['components'] as Map<String, Object?>?) ?? {};
    versions.forEach(
      (name, version) => components.putIfAbsent(name, () => {}).add('$version'),
    );
  }
  sources.sort();
  final out = StringBuffer()
    ..writeln('# Third-party notices')
    ..writeln()
    ..writeln(
      'The native libraries in this release are the prebuilt libvips '
      'libraries of the [sharp-libvips](https://github.com/lovell/sharp-libvips) '
      'project, repackaged unchanged. As a whole they are distributed under '
      'the **GNU Lesser General Public License v3.0 or later** (see '
      'LGPL-3.0.txt and GPL-3.0.txt). Each component keeps its own licence; '
      'the corresponding source of every component is pinned by the '
      'sharp-libvips build recipe attached to this release.',
    )
    ..writeln()
    ..writeln('## Sources')
    ..writeln()
    ..writeln('| Target | npm package | Integrity |')
    ..writeln('|--------|-------------|-----------|');
  sources.forEach(out.writeln);
  out
    ..writeln()
    ..writeln('## Bundled components')
    ..writeln()
    ..writeln('| Component | Version |')
    ..writeln('|-----------|---------|');
  for (final name in components.keys.toList()..sort()) {
    out.writeln(
      '| $name | ${(components[name]!.toList()..sort()).join(', ')} |',
    );
  }
  target.writeAsStringSync(out.toString());
  stdout.writeln('Wrote ${target.path}');
}
