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
}
