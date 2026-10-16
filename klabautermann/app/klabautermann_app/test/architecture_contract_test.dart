import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _packageDeclaration = 'name: klabautermann_app';

// 03 section 3.2: the app reaches seance_core types only through
// klabautermann_core's curated barrel, and dartssh2 only ever through
// seance_core (D4). Poltergeist's core is a sibling product, never a
// dependency.
const _forbiddenPackages = {
  'dartssh2',
  'poltergeist_core',
  'seance_core',
  'seance_protocol',
};
final _packageImport = RegExp(
  r'''^\s*(?:import|export)\s+['"]package:([a-z0-9_]+)/''',
  multiLine: true,
);
final _dependencyEntry = RegExp(r'^  ([a-z0-9_]+):', multiLine: true);

/// Every directory of the app's Dart sources, the frame-timing test's
/// (spike S5) included.
const _sourceDirectories = ['lib', 'test', 'integration_test', 'test_driver'];

void main() {
  setUpAll(() {
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync() ||
        !pubspec.readAsStringSync().contains(_packageDeclaration)) {
      fail('Run this suite from app/klabautermann_app so lib/ can be scanned.');
    }
  });

  test('the composition root spawns the engine with links off (03 '
      '§10.1)', () {
    final main = File('lib/main.dart').readAsStringSync();
    final spawn = RegExp(r'IsolateEngineClient\.spawn\(([^;]*)\);');

    expect(spawn.allMatches(main), hasLength(1));
    expect(spawn.firstMatch(main)![1], contains('linksEnabled: false'));
  });

  test('declares no SSH, protocol or sibling-core dependency', () {
    final declared = _dependencyEntry
        .allMatches(File('pubspec.yaml').readAsStringSync())
        .map((match) => match[1]!)
        .toSet();

    expect(declared.intersection(_forbiddenPackages), isEmpty);
  });

  test('imports no SSH, protocol or sibling-core package', () {
    final offenders = <String>[];
    for (final path in _sourceDirectories) {
      final directory = Directory(path);
      if (!directory.existsSync()) continue;

      for (final entity in directory.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;

        for (final match in _packageImport.allMatches(
          entity.readAsStringSync(),
        )) {
          if (_forbiddenPackages.contains(match[1])) {
            offenders.add('${entity.path}: package:${match[1]}');
          }
        }
      }
    }

    expect(offenders, isEmpty);
  });

  test('lib/ never imports the replay engine, test support for spike S5 '
      '(03 §11.4)', () {
    final offenders = [
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            entity.readAsStringSync().contains(
              'package:klabautermann_core/replay.dart',
            ))
          entity.path,
    ];

    expect(offenders, isEmpty);
  });

  test('recognizes the import forms the scan must catch', () {
    const sources = [
      "import 'package:seance_core/seance_core.dart';",
      'import "package:dartssh2/dartssh2.dart" show SSHClient;',
      "  export 'package:poltergeist_core/poltergeist_core.dart';",
    ];

    for (final source in sources) {
      expect(
        _forbiddenPackages,
        contains(_packageImport.firstMatch(source)?[1]),
        reason: source,
      );
    }
  });
}
