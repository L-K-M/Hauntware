// The CI tool stays outside the shipped packages.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../lib/guards_config.dart';

const _valid = '''
products:
  poltergeist:
    scan: [packages, app]
    pure_packages: [packages/*]
    dartssh2_imports:
      - packages/poltergeist_core/lib/src/connection
      - packages/poltergeist_bench
    dartssh2_dependents:
      - packages/poltergeist_core
      - packages/poltergeist_bench
    standalone_resolutions:
      - packages/poltergeist_bench
    engine_protocol: packages/poltergeist_core/lib/src/engine
    engine_protocol_callback_owners:
      packages/poltergeist_core/lib/src/engine/engine_probes.dart:
        [EngineProbes]
''';

const _extended = '''
products:
  seance:
    scan: [packages, app]
    pure_packages: [packages/seance_protocol]
    dartssh2_imports: [packages/seance_core/lib/src/ssh]
    dartssh2_dependents: [packages/seance_core]
    dartssh2_dev_dependents: [app/seance_app]
    import_exemptions: [app/seance_app/test/host_key_blocked_test.dart]
    no_dart_io: [packages/seance_protocol/lib]
    forbidden_dependencies:
      "ghost_*": [seance_core]
      ghost_ui: [ghost_theme]
    allowed_dependencies:
      ghost_servers: [flutter, "ghost_*", seance_protocol]
    seance_core_implementation_imports: [packages/seance_core]
    engine_protocol: null
    engine_protocol_callback_owners: {}
''';

GuardsConfig _parse(String yaml) =>
    GuardsConfig.parse(loadYaml(yaml), source: 'guards.yaml');

void main() {
  test('parses the shipped configuration', () async {
    final config = await loadGuardsConfig(File(guardsConfigPath).absolute);
    final product = config.product('poltergeist');
    expect(product.scan, ['packages', 'app']);
    expect(product.purePackages, ['packages/*']);
    expect(
      product.dartssh2Imports,
      containsAll([
        'packages/poltergeist_core/lib/src/connection',
        'packages/poltergeist_bench',
      ]),
    );
    expect(
      product.dartssh2Dependents,
      containsAll(['packages/poltergeist_core', 'packages/poltergeist_bench']),
    );
    expect(product.standaloneResolutions, ['packages/poltergeist_bench']);
    expect(product.engineProtocol, 'packages/poltergeist_core/lib/src/engine');
    expect(product.engineProtocolCallbackOwners, hasLength(3));
    expect(
      product
          .engineProtocolCallbackOwners['packages/poltergeist_core/lib/src/engine/engine_probes.dart'],
      ['EngineProbes'],
    );
    expect(
      product.seanceCoreImplementationImports,
      containsAll([
        'packages/poltergeist_core/lib/src/connection',
        'packages/poltergeist_core/test/connection',
        'packages/poltergeist_bench',
      ]),
    );

    final seance = config.product('seance');
    expect(seance.scan, ['packages', 'app']);
    expect(seance.purePackages, [
      'packages/seance_protocol',
      'packages/seance_core',
      'packages/seance_sync_server',
    ]);
    expect(seance.dartssh2DevDependents, ['app/seance_app']);
    expect(seance.importExemptions, [
      'app/seance_app/test/host_key_blocked_test.dart',
    ]);
    expect(seance.noDartIo, ['packages/seance_protocol/lib']);
    expect(seance.engineProtocol, isNull);

    final planchette = config.product('planchette');
    expect(planchette.scan, ['packages', 'app']);
    expect(planchette.purePackages, ['packages/planchette_core']);
    expect(planchette.forbiddenDependenciesFor('ghost_ui'), {
      'seance_core',
      'ghost_theme',
    });
    expect(planchette.forbiddenDependenciesFor('ghost_marks'), {'seance_core'});
  });

  test('matches pure packages through a directory wildcard', () {
    final product = _parse(_valid).product('poltergeist');
    expect(product.isPurePackage('packages/poltergeist_core'), isTrue);
    expect(product.isPurePackage('app/poltergeist_app'), isFalse);
    expect(product.isPurePackage('packages/poltergeist_core/nested'), isFalse);
    expect(
      product.allowsDartssh2Import(
        'packages/poltergeist_core/lib/src/connection/ssh.dart',
      ),
      isTrue,
    );
    expect(
      product.allowsDartssh2Import('packages/poltergeist_bench/lib/ssh.dart'),
      isTrue,
    );
    expect(
      product.allowsDartssh2Import('packages/poltergeist_core/lib/other.dart'),
      isFalse,
    );
    // Matching is per path segment, not by string prefix.
    expect(
      product.allowsDartssh2Import('packages/poltergeist_bench2/lib/ssh.dart'),
      isFalse,
    );
    expect(
      product.allowsDartssh2Import(
        'packages/poltergeist_core/lib/src/connection_extra/ssh.dart',
      ),
      isFalse,
    );
    expect(product.isPurePackage('packages2/poltergeist_core'), isFalse);
  });

  for (final entry in ['packages/*/lib', 'pack*', 'packages/poltergeist_*']) {
    test('rejects the wildcard $entry', () {
      expect(
        () => _parse(_valid.replaceFirst('[packages/*]', '[$entry]')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('invalid relative path'),
          ),
        ),
      );
    });
  }

  test('rejects a wildcard engine protocol directory', () {
    expect(
      () => _parse(
        _valid.replaceFirst(
          'engine_protocol: packages/poltergeist_core/lib/src/engine',
          'engine_protocol: packages/poltergeist_core/lib/src/*',
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  for (final key in [
    'pure_packages',
    'dartssh2_imports',
    'dartssh2_dependents',
    'engine_protocol_callback_owners',
  ]) {
    test('rejects a null $key', () {
      final yaml = _valid.replaceFirstMapped(
        RegExp('^    $key:.*\$', multiLine: true),
        (_) => '    $key: null',
      );
      expect(
        () => _parse(_withoutDanglingEntries(yaml, key)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('$key must not be null'),
          ),
        ),
      );
    });
  }

  test('rejects a callback owner outside the engine protocol', () {
    expect(
      () => _parse(
        _valid.replaceFirst(
          'packages/poltergeist_core/lib/src/engine/engine_probes.dart:',
          'packages/poltergeist_core/lib/src/other/engine_probes.dart:',
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('outside engine_protocol'),
        ),
      ),
    );
  });

  test('rejects callback owners without an engine protocol', () {
    expect(
      () => _parse(
        _valid.replaceFirst(
          'engine_protocol: packages/poltergeist_core/lib/src/engine',
          'engine_protocol: null',
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('must be empty when engine_protocol is null'),
        ),
      ),
    );
  });

  for (final yaml in [
    'products: {poltergeist: {scan: [packages], extra: true}}',
    'products: {poltergeist: {scan: [packages], pure_packages: []}}',
    'products: {poltergeist: {scan: []}}',
    'products: {}',
    'other: {}',
  ]) {
    test('fails closed on malformed configuration: $yaml', () {
      expect(() => _parse(yaml), throwsFormatException);
    });
  }

  test('fails closed on an unknown product key', () {
    expect(
      () => _parse(_valid.replaceFirst('pure_packages', 'pure_pkgs')),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('unknown key'), contains('pure_pkgs')),
        ),
      ),
    );
  });

  test('fails closed on a missing required key', () {
    expect(
      () => _parse(
        _valid.replaceFirst('engine_protocol_callback_owners:', 'removed:'),
      ),
      throwsFormatException,
    );
    expect(
      () => _parse('products: {poltergeist: {scan: [packages]}}'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('missing required key'),
        ),
      ),
    );
  });

  test('fails closed on an unknown product name', () {
    expect(
      () => _parse(_valid).product('seance'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('unknown product'),
        ),
      ),
    );
  });

  for (final name in ['.', '..', 'a/b', r'a\\b']) {
    test('fails closed on product name "$name"', () {
      expect(
        () => _parse(_valid.replaceFirst('poltergeist:', '"$name":')),
        throwsFormatException,
      );
    });
  }

  test('fails closed on an empty product name', () {
    expect(() => _parse('products: {"": {}}'), throwsFormatException);
  });

  for (final path in ['/abs', 'a/../b', 'a//b', 'a/']) {
    test('fails closed on product path "$path"', () {
      expect(
        () => _parse(
          _valid.replaceFirst(
            'packages/poltergeist_bench\n    dartssh2_dependents',
            '"$path"\n    dartssh2_dependents',
          ),
        ),
        throwsFormatException,
      );
    });
  }

  test('fails closed on a missing configuration file', () async {
    final missing = File(
      p.join(Directory.systemTemp.path, 'no-such-guards.yaml'),
    );
    await expectLater(loadGuardsConfig(missing), throwsA(anything));
  });

  test('fails closed on unreadable YAML', () {
    expect(() => _parse('products: [poltergeist'), throwsA(anything));
    expect(() => _parse('products: not a map'), throwsFormatException);
  });

  test('a product may declare no engine protocol', () {
    final product = _parse('''
products:
  seance:
    scan: [packages]
    pure_packages: [packages/*]
    dartssh2_imports: [packages/seance_core/lib/src/connection]
    dartssh2_dependents: [packages/seance_core]
    engine_protocol: null
    engine_protocol_callback_owners: {}
''').product('seance');
    expect(product.engineProtocol, isNull);
    expect(product.scanAreas, {'packages'});
  });

  test('defaults every optional rule key to empty', () {
    final product = _parse(_valid).product('poltergeist');
    expect(product.dartssh2DevDependents, isEmpty);
    expect(product.importExemptions, isEmpty);
    expect(product.noDartIo, isEmpty);
    expect(product.forbiddenDependencies, isEmpty);
    expect(product.allowedDependencies, isEmpty);
    expect(product.seanceCoreImplementationImports, isEmpty);
  });

  test('parses the extended rule keys', () {
    final product = _parse(_extended).product('seance');
    expect(product.dartssh2DevDependents, ['app/seance_app']);
    expect(product.importExemptions, [
      'app/seance_app/test/host_key_blocked_test.dart',
    ]);
    expect(product.noDartIo, ['packages/seance_protocol/lib']);
    expect(product.seanceCoreImplementationImports, ['packages/seance_core']);
    expect(product.forbiddenDependencies, {
      'ghost_*': ['seance_core'],
      'ghost_ui': ['ghost_theme'],
    });
    expect(product.allowedDependencies, {
      'ghost_servers': ['flutter', 'ghost_*', 'seance_protocol'],
    });
  });

  test('gives only a listed package an allowlist', () {
    final product = _parse(_extended).product('seance');
    expect(product.allowedDependenciesFor('ghost_servers'), {
      'flutter',
      'ghost_*',
      'seance_protocol',
    });
    expect(product.allowedDependenciesFor('ghost_ui'), isNull);
  });

  test('unions every matching forbidden-dependency key', () {
    final product = _parse(_extended).product('seance');
    expect(product.forbiddenDependenciesFor('ghost_ui'), {
      'seance_core',
      'ghost_theme',
    });
    expect(product.forbiddenDependenciesFor('ghost_marks'), {'seance_core'});
    expect(product.forbiddenDependenciesFor('planchette_core'), isEmpty);
  });

  test('matches package-name globs', () {
    expect(packageNameMatches('ghost_*', 'ghost_ui'), isTrue);
    expect(packageNameMatches('ghost_*', 'ghost_'), isTrue);
    expect(packageNameMatches('ghost_*', 'ghost'), isFalse);
    expect(packageNameMatches('ghost_ui', 'ghost_ui'), isTrue);
    expect(packageNameMatches('ghost_ui', 'ghost_uis'), isFalse);
    expect(packageNameMatches('seance_*', 'seance_core'), isTrue);
  });

  test('resolves rule paths by directory containment', () {
    final product = _parse(_extended).product('seance');
    expect(
      product.forbidsDartIo('packages/seance_protocol/lib/src/inbox.dart'),
      isTrue,
    );
    expect(
      product.forbidsDartIo('packages/seance_core/lib/src/inbox.dart'),
      isFalse,
    );
    expect(
      product.allowsSeanceCoreImplementationImport(
        'packages/seance_core/test/sync_test.dart',
      ),
      isTrue,
    );
    expect(
      product.allowsSeanceCoreImplementationImport(
        'app/seance_app/lib/main.dart',
      ),
      isFalse,
    );
    expect(
      product.isImportExempt('app/seance_app/test/host_key_blocked_test.dart'),
      isTrue,
    );
    expect(
      product.isImportExempt('app/seance_app/test/other_test.dart'),
      isFalse,
    );
    expect(product.allowsDartssh2DevDependency('app/seance_app'), isTrue);
    expect(product.allowsDartssh2Dependency('app/seance_app'), isFalse);
  });

  for (final entry in [
    'forbidden_dependencies: {"*": [seance_core]}',
    'forbidden_dependencies: {ghost_*: ["*bad"]}',
    'forbidden_dependencies: {"ghost ui": [seance_core]}',
    'forbidden_dependencies: {ghost_ui: [""]}',
  ]) {
    test('rejects an invalid forbidden dependency entry: $entry', () {
      expect(
        () => _parse(
          _extended.replaceFirst(
            '    forbidden_dependencies:\n'
                '      "ghost_*": [seance_core]\n'
                '      ghost_ui: [ghost_theme]',
            '    $entry',
          ),
        ),
        throwsFormatException,
      );
    });
  }

  for (final entry in [
    'allowed_dependencies: {"ghost_*": [ghost_ui]}',
    'allowed_dependencies: {ghost_servers: ["*"]}',
    'allowed_dependencies: {ghost_servers: [""]}',
    'allowed_dependencies: [ghost_servers]',
  ]) {
    test('rejects an invalid allowed dependency entry: $entry', () {
      expect(
        () => _parse(
          _extended.replaceFirst(
            '    allowed_dependencies:\n'
                '      ghost_servers: [flutter, "ghost_*", seance_protocol]',
            '    $entry',
          ),
        ),
        throwsFormatException,
      );
    });
  }
}

/// Drops the indented list or map lines that followed [key] once its value
/// is replaced by `null`, so the YAML stays well-formed.
String _withoutDanglingEntries(String yaml, String key) {
  final lines = yaml.split('\n');
  final out = <String>[];
  var skipping = false;

  for (final line in lines) {
    if (line == '    $key: null') {
      skipping = true;
      out.add(line);
      continue;
    }
    if (skipping && (line.trim().isEmpty || line.startsWith('      '))) {
      continue;
    }
    skipping = false;
    out.add(line);
  }

  return out.join('\n');
}
