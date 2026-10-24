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
final _configDraftImport = RegExp(
  r'''^\s*(?:import|export)\s+['"]package:ghost_servers/server_config_draft\.dart''',
  multiLine: true,
);

/// seance_terminal, which the app may use (docs/design/seance-terminal.md
/// 3.4), read by its monorepo path so the contract holds before the app
/// depends on it.
const _terminalPackage = '../../../seance/packages/seance_terminal';
const _terminalBarrel = 'package:seance_terminal/seance_terminal.dart';
final _terminalImport = RegExp(
  r'''^\s*(?:import|export)\s+['"](package:seance_terminal/[^'"]*)['"]''',
  multiLine: true,
);

/// An `export` directive and its `show` list, if any, up to its `;`.
final _exportDirective = RegExp(
  r'''^\s*export\s+['"]([^'"]+)['"]([^;]*);''',
  multiLine: true,
);

/// The packages whose names seance_terminal must not pass on to the app.
const _terminalHiddenPackages = ['seance_core', 'seance_protocol', 'dartssh2'];
const _terminalHiddenSources = [
  '../../../seance/packages/seance_core/lib',
  '../../../seance/packages/seance_protocol/lib',
];

/// Top-level declarations: classes, enums, mixins, typedefs, extensions
/// and extension types, functions, and variables, constants and getters.
final _topLevelName = RegExp(
  r'^(?:(?:abstract|base|final|interface|sealed|mixin)\s+)*'
  r'(?:class|enum|mixin|typedef|extension(?:\s+type)?)\s+([A-Za-z_]\w*)'
  r'|^(?:external\s+)?(?:(?:const|final|var|late)\s+)*'
  r'(?:[A-Za-z_][\w<>?, ]*\s+)?(?:get\s+)?([A-Za-z_]\w*)\s*(?:[=(;]|=>)',
  multiLine: true,
);

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

  // The engine's own defaults are off (EngineStart.linksEnabled,
  // EngineStart.probesEnabled), so the app connects and probes only
  // because the composition root asks.
  test('the composition root spawns the engine with links and probes on '
      '(03 §10.1, §5.12)', () {
    final main = File('lib/main.dart').readAsStringSync();
    final spawn = RegExp(r'IsolateEngineClient\.spawn\(([^;]*)\);');

    expect(spawn.allMatches(main), hasLength(1));
    expect(spawn.firstMatch(main)![1], contains('linksEnabled: true'));
    expect(spawn.firstMatch(main)![1], contains('probesEnabled: true'));
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

  // ghost_servers maps its editor drafts to protocol configs in a library
  // of its own, kept out of the barrel for hosts that may import
  // seance_protocol (docs/design/ghost-servers-part2.md, section 2).
  test('imports no protocol-typed ghost_servers library', () {
    expect(
      _configDraftImport.hasMatch(
        "import 'package:ghost_servers/server_config_draft.dart';",
      ),
      isTrue,
    );
    final offenders = [
      for (final path in _sourceDirectories)
        if (Directory(path).existsSync())
          for (final entity in Directory(path).listSync(recursive: true))
            if (entity is File &&
                entity.path.endsWith('.dart') &&
                _configDraftImport.hasMatch(entity.readAsStringSync()))
              entity.path,
    ];

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

  group('seance_terminal (docs/design/seance-terminal.md 3.4)', () {
    test('stays allowed, and only through its barrel', () {
      expect(_forbiddenPackages, isNot(contains('seance_terminal')));

      final offenders = <String>[];
      for (final path in _sourceDirectories) {
        final directory = Directory(path);
        if (!directory.existsSync()) continue;
        for (final entity in directory.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          for (final match in _terminalImport.allMatches(
            entity.readAsStringSync(),
          )) {
            if (match[1] != _terminalBarrel) {
              offenders.add('${entity.path}: ${match[1]}');
            }
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('exports no SSH or protocol package', () {
      final offenders = <String>[];
      for (final entity in Directory(
        '$_terminalPackage/lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final match in _exportDirective.allMatches(
          entity.readAsStringSync(),
        )) {
          final uri = match[1]!;
          if (_terminalHiddenPackages.any(
            (name) => uri.startsWith('package:$name/'),
          )) {
            offenders.add('${entity.path}: $uri');
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('shows each barrel name, none of them seance_core\'s or '
        'seance_protocol\'s', () {
      final barrel = File('$_terminalPackage/lib/seance_terminal.dart')
          .readAsStringSync();
      final exports = _exportDirective.allMatches(barrel).toList();
      expect(exports, isNotEmpty);

      final shown = <String>{};
      for (final export in exports) {
        final clause = export[2]!.trim();
        expect(clause, startsWith('show'), reason: export[1]);
        shown.addAll(
          clause
              .substring('show'.length)
              .split(',')
              .map((name) => name.trim())
              .where((name) => name.isNotEmpty),
        );
      }

      final hidden = <String>{
        for (final root in _terminalHiddenSources)
          for (final entity in Directory(root).listSync(recursive: true))
            if (entity is File && entity.path.endsWith('.dart'))
              for (final match in _topLevelName.allMatches(
                entity.readAsStringSync(),
              ))
                ?(match[1] ?? match[2]),
      };
      expect(hidden, contains('SessionTransport'), reason: 'the scan works');
      expect(shown.intersection(hidden), isEmpty);
    });
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
