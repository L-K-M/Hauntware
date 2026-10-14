// The CI tool stays outside the shipped packages.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../import_guard/lib/guards_config.dart';
import '../lib/protocol_guard.dart';

const _product = 'poltergeist';
const _core = '$_product/packages/poltergeist_core';
const _engine = '$_core/lib/src/engine';

// The same entry tool/guards.yaml carries for Poltergeist; the guard
// checks reported paths against it from the fixture's repository root.
const _guardsConfig = '''
products:
  poltergeist:
    scan: [packages, app]
    pure_packages: [packages/*]
    dartssh2_imports: []
    dartssh2_dependents: []
    engine_protocol: packages/poltergeist_core/lib/src/engine
    engine_protocol_callback_owners:
      packages/poltergeist_core/lib/src/engine/progress_coalescer.dart:
        [ProgressCoalescer]
      packages/poltergeist_core/lib/src/engine/connect_log_coalescer.dart:
        [ConnectLogCoalescer]
      packages/poltergeist_core/lib/src/engine/engine_probes.dart:
        [EngineProbes]
''';

// A product with no engine, as Séance and Planchette declare it.
const _noEngineConfig = '''
products:
  seance:
    scan: [packages, app]
    pure_packages: [packages/seance_core]
    dartssh2_imports: []
    dartssh2_dependents: []
    engine_protocol: null
    engine_protocol_callback_owners: {}
''';

void main() {
  late _Fixture fixture;
  setUp(() async => fixture = await _Fixture._create());
  tearDown(() async => fixture._root.delete(recursive: true));

  test(
    'accepts data fields, methods, getters, comments, and strings',
    () async {
      await fixture._write('$_engine/data.dart', '''
// Function callback; class Escaped extends EngineEvent {}
class Data {
  final bytes = 3;
  final label = 'void Function() callback';
  void consume(void Function() callback) => callback();
  void Function() get callback => () {};
}
''');
      expect(await fixture._check(), isEmpty);
    },
  );

  for (final declaration in [
    'late Function callback;',
    'late Function? callback;',
    'late void Function() callback;',
    'late Callback callback;',
    'final callback = () {};',
    'final callback = tearOff;',
    'static final callback = tearOff;',
    'late T callback;',
    'late List<Callback> callback;',
    'late ({Callback callback, int bytes}) callback;',
  ]) {
    test('rejects resolved callback field: $declaration', () async {
      await fixture._write('$_engine/types.dart', '''
typedef Callback = void Function();
void tearOff() {}
''');
      await fixture._write('$_engine/data.dart', '''
import 'types.dart';
class Data<T extends Function> { $declaration }
''');
      expect(await fixture._check(), [contains('Data.callback')]);
    });
  }

  test('allows only the named internal class in its exact file', () async {
    await fixture._write('$_engine/progress_coalescer.dart', '''
class ProgressCoalescer { final callback = () {}; }
class Other { final callback = () {}; }
''');
    await fixture._write('$_engine/connect_log_coalescer.dart', '''
class ConnectLogCoalescer { final callback = () {}; }
class OtherLog { final callback = () {}; }
''');
    await fixture._write('$_engine/elsewhere.dart', '''
class ProgressCoalescer { final callback = () {}; }
class ConnectLogCoalescer { final callback = () {}; }
''');
    final violations = await fixture._check();
    expect(violations, hasLength(4));
    expect(violations, contains(contains('Other.callback')));
    expect(violations, contains(contains('OtherLog.callback')));
    expect(violations, contains(contains('elsewhere.dart: ProgressCoalescer')));
    expect(
      violations,
      contains(contains('elsewhere.dart: ConnectLogCoalescer')),
    );
  });

  test('an allowlisted class cannot become a protocol subtype', () async {
    await fixture._write('$_engine/progress_coalescer.dart', '''
import 'protocol.dart';
class ProgressCoalescer extends EngineEvent { final callback = () {}; }
''');
    expect(await fixture._check(), [contains('ProgressCoalescer.callback')]);
  });

  test('probe callbacks stay confined to the internal owner', () async {
    await fixture._write('$_engine/engine_probes.dart', '''
class EngineProbes { final callback = () {}; }
class Other { final callback = () {}; }
''');
    await fixture._write('$_engine/elsewhere.dart', '''
class EngineProbes { final callback = () {}; }
''');
    expect(await fixture._check(), [
      contains('elsewhere.dart: EngineProbes.callback'),
      contains('engine_probes.dart: Other.callback'),
    ]);
  });

  test('probe callback owner cannot become a protocol payload', () async {
    await fixture._write('$_engine/engine_probes.dart', '''
import 'protocol.dart';
class EngineProbes extends EngineEvent { final callback = () {}; }
''');
    expect(await fixture._check(), [contains('EngineProbes.callback')]);
  });

  test(
    'the connect-log coalescer cannot become a protocol subtype either',
    () async {
      await fixture._write('$_engine/connect_log_coalescer.dart', '''
import 'protocol.dart';
class ConnectLogCoalescer extends EngineEvent { final callback = () {}; }
''');
      expect(await fixture._check(), [
        contains('ConnectLogCoalescer.callback'),
      ]);
    },
  );

  for (final source in [
    'class Escaped extends EngineEvent {}',
    'class Escaped implements EngineRequest {}',
    'class Escaped extends Intermediate {}',
    'typedef Alias = EngineEvent; class Escaped extends Alias {}',
    'mixin Helper {} class Escaped = EngineEvent with Helper;',
    'enum Escaped implements EngineEvent { value }',
    'extension type Escaped(Intermediate value) implements EngineEvent {}',
  ]) {
    test('rejects relocated protocol subtype: $source', () async {
      await fixture._write('$_core/lib/escaped.dart', '''
import 'src/engine/protocol.dart';
$source
''');
      expect(await fixture._check(), [contains('Escaped is outside engine/')]);
    });
  }

  test('rejects an extension type callback representation', () async {
    await fixture._write('$_engine/wrapper.dart', '''
extension type Wrapper(void Function() callback) {}
''');
    expect(await fixture._check(), [contains('Wrapper.callback')]);
  });

  for (final fieldType in [
    'CallbackWrapper',
    'Nested',
    'Generic<int>',
    'Container<CallbackWrapper>',
    'List<CallbackWrapper>',
    '({CallbackWrapper value, int bytes})',
  ]) {
    test('rejects external callback wrapper field: $fieldType', () async {
      await fixture._write('$_core/lib/wrapper.dart', '''
extension type CallbackWrapper(void Function() value) {}
extension type Nested(CallbackWrapper value) {}
extension type Generic<T>(void Function(T) value) {}
extension type Container<T>(T value) {}
''');
      await fixture._write('$_engine/data.dart', '''
import '../../wrapper.dart';
class Data { late $fieldType callback; }
''');
      expect(await fixture._check(), [contains('Data.callback')]);
    });
  }

  test(
    'allows a phantom callback argument with an integer representation',
    () async {
      await fixture._write('$_core/lib/wrapper.dart', '''
extension type Phantom<T>(int value) {}
''');
      await fixture._write('$_engine/data.dart', '''
import '../../wrapper.dart';
class Data { late Phantom<void Function()> value; }
''');
      expect(await fixture._check(), isEmpty);
    },
  );

  for (final (base, declaration) in [
    (
      'class Base { final void Function() callback = () {}; }',
      'class Data extends Base {}',
    ),
    ('mixin Hooks { final callback = () {}; }', 'class Data with Hooks {}'),
    (
      'class Base<T> { late T callback; }',
      'class Data extends Base<void Function()> {}',
    ),
    (
      'class Base<T> { late T callback; } '
          'class Middle<U> extends Base<List<U>> {}',
      'class Data extends Middle<void Function()> {}',
    ),
    (
      'class Base { final void Function() callback = () {}; }',
      'class Data extends Base { '
          '@override void Function() get callback => () {}; }',
    ),
  ]) {
    test('rejects inherited callback storage: $declaration', () async {
      await fixture._write('$_core/lib/base.dart', base);
      await fixture._write('$_engine/data.dart', '''
import '../../base.dart';
$declaration
''');
      expect(await fixture._check(), [contains('Data.callback')]);
    });
  }

  test('rejects inherited private callback storage', () async {
    await fixture._write('$_core/lib/base.dart', '''
class Base { final _callback = () {}; }
''');
    await fixture._write('$_engine/data.dart', '''
import '../../base.dart';
class Data extends Base {}
''');
    expect(await fixture._check(), [contains('Data._callback')]);
  });

  test('allows static superclass callbacks and computed getters', () async {
    await fixture._write('$_core/lib/base.dart', '''
class Base {
  static final callback = () {};
  void Function() get computed => () {};
}
''');
    await fixture._write('$_engine/data.dart', '''
import '../../base.dart';
class Data extends Base {}
''');
    expect(await fixture._check(), isEmpty);
  });

  test(
    'allows interface-only callback fields implemented by getters',
    () async {
      await fixture._write('$_core/lib/base.dart', '''
class Base { final void Function() callback = () {}; }
''');
      await fixture._write('$_engine/data.dart', '''
import '../../base.dart';
class Data implements Base {
  @override void Function() get callback => () {};
}
''');
      expect(await fixture._check(), isEmpty);
    },
  );

  test('an allowlisted payload cannot use inherited callbacks', () async {
    await fixture._write('$_core/lib/base.dart', '''
class Base { final void Function() callback = () {}; }
''');
    await fixture._write('$_engine/progress_coalescer.dart', '''
import '../../base.dart';
import 'protocol.dart';
class ProgressCoalescer extends Base implements EngineEvent {}
''');
    expect(await fixture._check(), [contains('ProgressCoalescer.callback')]);
  });

  test(
    'detects relocation into app despite unresolved Flutter imports',
    () async {
      await fixture._write('$_product/app/poltergeist_app/lib/escaped.dart', '''
import 'package:flutter/widgets.dart';
import 'package:poltergeist_core/src/engine/protocol.dart' as engine;
class Escaped extends engine.EngineEvent {}
''');
      expect(await fixture._check(), [contains('Escaped is outside engine/')]);
    },
  );

  test(
    'finds callbacks in mixins and source directories named build',
    () async {
      await fixture._write('$_engine/build/hooks.dart', '''
mixin Hooks { final callback = () {}; }
''');
      expect(await fixture._check(), [contains('Hooks.callback')]);
    },
  );

  test('ignores generated outputs and the benchmark harness', () async {
    for (final directory in [
      '$_core/build',
      '$_product/app/poltergeist_app/linux/flutter/ephemeral',
      '$_product/tool/bench/lib',
    ]) {
      await fixture._write('$directory/generated.dart', 'not valid Dart');
    }
    expect(await fixture._check(), isEmpty);
  });

  for (final directory in ['$_product/packages', '$_product/app', _engine]) {
    test('fails closed without $directory', () async {
      await Directory(
        p.join(fixture._root.path, directory),
      ).delete(recursive: true);
      await expectLater(fixture._check(), throwsA(isA<FileSystemException>()));
    });
  }

  test('a product with no engine has no protocol to enforce', () async {
    final seance = GuardsConfig.parse(
      loadYaml(_noEngineConfig),
      source: 'guards.yaml',
    ).product('seance');
    expect(await checkProtocol(fixture._root.path, seance), isEmpty);
  });

  test('a guards config omitting engine_protocol fails closed at parse', () {
    const missingKey = '''
products:
  seance:
    scan: [packages, app]
    pure_packages: [packages/seance_core]
    dartssh2_imports: []
    dartssh2_dependents: []
    engine_protocol_callback_owners: {}
''';
    expect(
      () => GuardsConfig.parse(
        loadYaml(missingKey),
        source: 'guards.yaml',
      ).product('seance'),
      throwsFormatException,
    );
  });

  test('fails closed on an empty engine directory', () async {
    await File(p.join(fixture._root.path, '$_engine/protocol.dart')).delete();
    await expectLater(fixture._check(), throwsFormatException);
  });

  test('fails closed on malformed Dart', () async {
    await fixture._write('$_engine/data.dart', 'class Unfinished {');
    await expectLater(fixture._check(), throwsA(anything));
  });

  test('fails closed on an unresolved engine field type', () async {
    await fixture._write(
      '$_engine/data.dart',
      'class Data { late Unknown field; }',
    );
    await expectLater(fixture._check(), throwsFormatException);
  });

  test('fails closed on linked engine input', () async {
    await Link(
      p.join(fixture._root.path, '$_engine/linked.dart'),
    ).create('protocol.dart');
    await expectLater(fixture._check(), throwsA(isA<FileSystemException>()));
  });

  test(
    'CLI exits distinguish clean, violations, and scan failures',
    () async {
      await fixture._expectExit(0);
      await fixture._write(
        '$_engine/data.dart',
        'class Data { final callback = () {}; }',
      );
      await fixture._expectExit(1, 'Data.callback');
      await fixture._write('$_engine/data.dart', 'class Unfinished {');
      await fixture._expectExit(2, 'protocol scan failed');
    },
    // Three cold `dart run` starts sit near the 30 s default on loaded
    // runners; the assertion is about exit codes, not startup speed.
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _Fixture {
  _Fixture(this._root, this._guard);

  /// The fixture repository root; `poltergeist/` is the product inside it.
  final Directory _root;
  final ProductGuard _guard;

  static Future<_Fixture> _create() async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('protocol-guard-'),
      GuardsConfig.parse(
        loadYaml(_guardsConfig),
        source: 'guards.yaml',
      ).product(_product),
    );
    await fixture._write('tool/guards.yaml', _guardsConfig);
    // The CLI subprocess resolves the tool through a root package config
    // like the real run; the copied entries keep their pub-cache rootUris.
    final toolConfig = File('.dart_tool/package_config.json').absolute;
    final config =
        jsonDecode(await toolConfig.readAsString()) as Map<String, dynamic>;
    for (final entry
        in (config['packages'] as List).cast<Map<String, dynamic>>()) {
      entry['rootUri'] = toolConfig.uri
          .resolve(entry['rootUri'] as String)
          .toString();
    }
    await fixture._write('.dart_tool/package_config.json', jsonEncode(config));
    await fixture._write('$_core/pubspec.yaml', '''
name: poltergeist_core
environment: {sdk: ^3.12.0}
''');
    await fixture._write(
      '$_product/.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'poltergeist_core',
            'rootUri': '../packages/poltergeist_core',
            'packageUri': 'lib/',
            'languageVersion': '3.12',
          },
        ],
      }),
    );
    await fixture._write('$_engine/protocol.dart', '''
abstract class EngineRequest {}
abstract class EngineEvent {}
class Intermediate extends EngineEvent {}
''');
    await Directory(p.join(fixture._root.path, '$_product/app')).create();
    return fixture;
  }

  Future<void> _write(String path, String contents) async {
    final file = File(p.join(_root.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<List<String>> _check() => checkProtocol(_root.path, _guard);

  Future<void> _expectExit(int expected, [String? diagnostic]) async {
    // Resolve from the suite root so nested test invocations find the same
    // CLI; the subprocess runs it from the fixture root like the real job.
    final suite = await Isolate.resolvePackageUri(
      Uri.parse('package:hauntware/'),
    );
    if (suite == null) throw StateError('Root package is unresolved');

    final script = suite.resolve('../tool/protocol_guard/bin/check.dart');
    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=${p.join(_root.path, '.dart_tool/package_config.json')}',
      script.toFilePath(),
      '--product',
      _guard.name,
    ], workingDirectory: _root.path);
    expect(
      result.exitCode,
      expected,
      reason: '${result.stdout}\n${result.stderr}',
    );
    if (diagnostic != null) expect(result.stderr, contains(diagnostic));
  }
}
