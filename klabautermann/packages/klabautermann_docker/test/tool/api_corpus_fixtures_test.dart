// Smoke checks of the committed recorded Docker API corpora (03 §11.1,
// D21): every recorded exchange parses as an HTTP response and agrees
// with its manifest. Replaying them through the client is D02's suite.
import 'dart:io';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import '../../tool/src/api_corpus.dart';
import '../harness.dart';

/// The corpora 03 §11.1 and 04's M3 exit name.
const _expected = [
  'api-1.41',
  'api-1.44',
  'api-1.52',
  'api-1.55',
  'api-podman',
];

void main() {
  final dirs = [
    for (final entry in fixturesDirectory.listSync())
      if (entry is Directory && _name(entry).startsWith('api-')) entry,
  ]..sort((a, b) => _name(a).compareTo(_name(b)));

  test('holds the corpora the design names', () {
    expect([for (final d in dirs) _name(d)], _expected);
  });

  final corpora = {
    for (final dir in dirs)
      _name(dir): readCorpus((file) {
        final f = File('${dir.path}/$file');
        return f.existsSync() ? f.readAsBytesSync() : null;
      }),
  };

  for (final dir in dirs) {
    final name = _name(dir);
    group(name, () {
      test('names itself and its daemon\'s API maximum', () {
        final (manifest, _) = corpora[name]!;
        expect(manifest.corpus, name);
        final suffix = name.substring('api-'.length);
        if (suffix == 'podman') {
          expect(manifest.daemon.runtime, 'podman');
        } else {
          expect(manifest.daemon.runtime, 'docker');
          expect(manifest.daemon.apiVersion, suffix);
        }
      });

      test('holds exactly the files its manifest lists', () {
        final (manifest, _) = corpora[name]!;
        expect(
          [for (final f in dir.listSync()) _name(f)]..sort(),
          [
            manifestFileName,
            sourceFileName,
            for (final e in manifest.exchanges) e.file,
          ]..sort(),
        );
      });

      test('matches itself in check mode', () {
        expect(compareCorpora(corpora[name]!, corpora[name]!), isEmpty);
      });

      test('records complete responses except the cut streams', () {
        final (manifest, shapes) = corpora[name]!;
        for (final entry in manifest.exchanges) {
          final raw = File('${dir.path}/${entry.file}').readAsBytesSync();
          final response = parseRecordedResponse(
            raw,
            headRequest: entry.method == 'HEAD',
          );
          expect(
            response.complete,
            entry.truncatedAfterLines == null,
            reason: entry.name,
          );
        }
        expect({
          for (final s in shapes) s.name: s.bodyKind,
        }, containsPair('logs-follow', BodyKind.stdcopy));
      });
    });
  }

  test('every corpus records the same exchanges', () {
    final lists = {
      for (final MapEntry(:key, value: (manifest, _)) in corpora.entries)
        key: [for (final e in manifest.exchanges) e.name],
    };
    for (final list in lists.values) {
      expect(list, lists.values.first);
    }
  });

  test('its newest Docker API is the client\'s tested maximum (D21)', () {
    final versions = [
      for (final (manifest, _) in corpora.values)
        if (manifest.daemon.runtime == 'docker')
          ApiVersion.tryParse(manifest.daemon.apiVersion)!,
    ]..sort();
    expect(versions.last, clientMaxTestedApiVersion);
    expect(versions.first, clientApiFloor);
  });
}

String _name(FileSystemEntity e) =>
    e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
