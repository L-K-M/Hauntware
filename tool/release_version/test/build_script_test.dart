@TestOn('posix')
library;

// Release tooling stays outside the shipped applications.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'hauntware-build-script-test-',
    );
    _writeProducts(sandbox);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('--check prints the resolved config without building', () async {
    final result = await _runBuild(sandbox, ['--check']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('planchette'));
    expect(result.stdout, contains('seance'));
    expect(result.stdout, contains('poltergeist'));
    expect(result.stdout, contains('ready'));
    expect(result.stdout, contains('missing'));
    // --check builds nothing.
    expect(Directory(p.join(sandbox.path, 'dist')).existsSync(), isFalse);
  });

  test('--help prints the contract header', () async {
    final result = await _runBuild(sandbox, ['--help']);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('Usage'));
  });

  test('unknown arguments fail with a usage hint', () async {
    final result = await _runBuild(sandbox, ['--bogus']);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Unknown argument'));
  });

  test(
    'a default run builds feasible products, skips missing, stages dist',
    () async {
      final result = await _runBuild(sandbox, const []);

      expect(result.exitCode, 0, reason: result.stderr as String);
      // The fake product builds emitted their marker artifacts.
      expect(
        File(p.join(sandbox.path, 'dist', 'planchette-artifact')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(sandbox.path, 'dist', 'seance-artifact')).existsSync(),
        isTrue,
      );
      // poltergeist has no build script in this fixture — skipped.
      expect(result.stdout, contains('skip poltergeist'));
      expect(result.stdout, contains('Build summary'));
    },
  );

  test('an explicitly named missing product fails', () async {
    final result = await _runBuild(sandbox, ['poltergeist']);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('poltergeist'));
  });

  test('a failing product build propagates a nonzero exit', () async {
    final result = await _runBuild(
      sandbox,
      const [],
      environment: {'FAKE_BUILD_FAIL': 'seance'},
    );

    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('seance  FAILED'));
    // The summary still reports the products that built.
    expect(result.stdout, contains('planchette  built'));
  });

  test('--debug forwards the debug profile to each product', () async {
    final result = await _runBuild(sandbox, ['--debug', 'seance']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(
      File(p.join(sandbox.path, 'seance', 'mode.marker')).readAsStringSync(),
      contains('--debug'),
    );
  });

  group('--install', () {
    test('forwards --install to each product and opens /Applications on '
        'macOS', () async {
      final host = _fakeHost(sandbox, 'Darwin');
      final result = await _runBuild(sandbox, [
        '--install',
        '--debug',
      ], environment: host.environment);

      expect(result.exitCode, 0, reason: result.stderr as String);
      for (final product in ['planchette', 'seance']) {
        final args = File(
          p.join(sandbox.path, product, 'mode.marker'),
        ).readAsStringSync();
        expect(args, contains('--install'), reason: product);
        expect(args, contains('--debug'), reason: product);
      }
      // One Finder window: /Applications, not dist/.
      expect(host.opened(), ['/Applications']);
    });

    test('opens nothing on other hosts', () async {
      final host = _fakeHost(sandbox, 'Linux');
      final result = await _runBuild(sandbox, [
        '--install',
      ], environment: host.environment);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(host.opened(), isEmpty);
    });

    test('--check reports the install mode', () async {
      final result = await _runBuild(sandbox, ['--check', '--install']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('Install: yes'));
    });
  });

  test('a default macOS run opens dist/ once, not per product', () async {
    final host = _fakeHost(sandbox, 'Darwin');
    final result = await _runBuild(
      sandbox,
      const [],
      environment: host.environment,
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(host.opened(), [p.join(sandbox.path, 'dist')]);
    // Products learn they are orchestrated, so they reveal nothing.
    expect(
      File(
        p.join(sandbox.path, 'seance', 'orchestrated.marker'),
      ).readAsStringSync(),
      '1',
    );
  });

  test('Séance stops before Flutter on macOS without CocoaPods', () async {
    // A copy of the real product script in a scratch tree, so a regression
    // cannot reach Flutter or write into the checkout.
    final seance = Directory(p.join(sandbox.path, 'seance-real'));
    Directory(
      p.join(seance.path, 'app', 'seance_app', 'macos'),
    ).createSync(recursive: true);
    final script = File(p.join(seance.path, 'scripts', 'build.sh'));
    script.parent.createSync();
    File(
      p.join(_repositoryRoot().path, 'seance', 'scripts', 'build.sh'),
    ).copySync(script.path);
    final host = _fakeHost(sandbox, 'Darwin');
    final bin = p.join(sandbox.path, 'fake-bin');
    final flutterLog = File(p.join(sandbox.path, 'flutter.log'));
    Directory(bin).createSync(recursive: true);
    File(p.join(bin, 'flutter')).writeAsStringSync('''#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${flutterLog.path}"
''');
    Process.runSync('chmod', ['+x', p.join(bin, 'flutter')]);

    final result = await Process.run(
      'bash',
      [script.path, 'app'],
      environment: {
        ...Platform.environment,
        ...host.environment,
        // System directories only: no CocoaPods, whatever the test host has.
        'PATH': '$bin:/usr/bin:/bin',
      },
    );

    expect(
      result.exitCode,
      isNot(0),
      reason: '${result.stdout}${result.stderr}',
    );
    expect(result.stderr, contains('CocoaPods'));
    expect(flutterLog.existsSync(), isFalse);
  });

  // An incremental Xcode build does not re-seal an existing bundle after
  // Flutter's embed phase rewrites its frameworks, so each product script
  // must hand Flutter a build tree without the previous app.
  group('a macOS build starts without the previous app bundle', () {
    for (final (product, appDir, bundle) in const [
      ('planchette', 'planchette_app', 'Planchette.app'),
      ('seance', 'seance_app', 'Seance.app'),
      ('poltergeist', 'poltergeist_app', 'Poltergeist.app'),
    ]) {
      test(product, () async {
        final root = Directory(p.join(sandbox.path, '$product-real'));
        final app = p.join(root.path, 'app', appDir);
        Directory(p.join(app, 'macos')).createSync(recursive: true);
        final products = p.join(app, 'build', 'macos', 'Build', 'Products');
        Directory(
          p.join(products, 'Release', bundle, 'Contents'),
        ).createSync(recursive: true);
        final script = File(p.join(root.path, 'scripts', 'build.sh'))
          ..parent.createSync();
        File(
          p.join(_repositoryRoot().path, product, 'scripts', 'build.sh'),
        ).copySync(script.path);

        final host = _fakeHost(sandbox, 'Darwin');
        final bin = p.join(sandbox.path, 'fake-bin');
        final buildLog = File(p.join(sandbox.path, 'flutter-build.log'));
        // At `flutter build`, record which bundles the build tree still has.
        File(p.join(bin, 'flutter')).writeAsStringSync('''#!/usr/bin/env bash
if [[ "\$1" == build ]]; then
  ls "${p.join(products, 'Release')}" > "${buildLog.path}"
fi
''');
        File(p.join(bin, 'pod')).writeAsStringSync('#!/usr/bin/env bash\n');
        Process.runSync('chmod', [
          '+x',
          p.join(bin, 'flutter'),
          p.join(bin, 'pod'),
        ]);

        final result = await Process.run(
          'bash',
          [script.path, 'app'],
          environment: {...Platform.environment, ...host.environment},
        );

        expect(
          buildLog.existsSync(),
          isTrue,
          reason: '${result.stdout}${result.stderr}',
        );
        expect(buildLog.readAsStringSync(), isNot(contains(bundle)));
        // Only the bundle goes; the rest of the build tree is the cache.
        expect(Directory(p.join(products, 'Release')).existsSync(), isTrue);
      });
    }
  });

  // A step that fails after its build succeeded must still fail the run:
  // the suite build reads the exit status to decide what it ships.
  group('a product build fails when a later step fails', () {
    for (final (product, appDir) in const [
      ('seance', 'seance_app'),
      ('poltergeist', 'poltergeist_app'),
    ]) {
      test('$product: the app cannot be copied into dist/', () async {
        final build = _realProductBuild(sandbox, product, appDir, 'Linux');
        // A file where dist/ belongs makes every copy into it fail.
        File(p.join(build.root, 'dist')).writeAsStringSync('');

        final result = await build.run(['app']);

        expect(result.exitCode, isNot(0), reason: '${result.stdout}');
        expect(result.stdout, contains('app: FAILED'));
      });

      test('$product: the APK cannot be copied into dist/', () async {
        final build = _realProductBuild(sandbox, product, appDir, 'Linux');
        File(p.join(build.root, 'dist')).writeAsStringSync('');

        final result = await build.run(['apk']);

        expect(result.exitCode, isNot(0), reason: '${result.stdout}');
        expect(result.stdout, contains('apk: FAILED'));
      });

      test('$product: Linux packaging fails', () async {
        final build = _realProductBuild(sandbox, product, appDir, 'Linux');
        final packager = File(
          p.join(build.root, 'scripts', 'package-linux.sh'),
        )..writeAsStringSync('#!/usr/bin/env bash\nexit 1\n');
        Process.runSync('chmod', ['+x', packager.path]);

        final result = await build.run(['app']);

        expect(result.exitCode, isNot(0), reason: '${result.stdout}');
        expect(result.stdout, contains('packages: FAILED'));
      });
    }

    test('seance: the server binary cannot be copied into dist/', () async {
      final build = _realProductBuild(sandbox, 'seance', 'seance_app', 'Linux');
      File(p.join(build.root, 'dist')).writeAsStringSync('');

      final result = await build.run(['server']);

      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      expect(result.stdout, contains('server: FAILED'));
      expect(result.stdout, isNot(contains('server: built')));
    });
  });

  test('runs from an arbitrary working directory', () async {
    final elsewhere = Directory(p.join(sandbox.path, 'elsewhere'))
      ..createSync();
    final script = File(p.join(_repositoryRoot().path, 'scripts', 'build.sh'));
    final result = await Process.run(
      'bash',
      [script.path, '--check'],
      workingDirectory: elsewhere.path,
      environment: {
        ...Platform.environment,
        'HAUNTWARE_BUILD_ROOT': sandbox.path,
      },
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('Root:  ${sandbox.path}'));
  });
}

Future<ProcessResult> _runBuild(
  Directory root,
  List<String> arguments, {
  Map<String, String> environment = const {},
}) {
  return Process.run(
    'bash',
    [p.join(_repositoryRoot().path, 'scripts', 'build.sh'), ...arguments],
    environment: {
      ...Platform.environment,
      ...environment,
      'HAUNTWARE_BUILD_ROOT': root.path,
    },
  );
}

/// A copy of [product]'s real build script in a scratch tree on a fake
/// [system] host whose tools succeed: `dart` and `flutter` write the
/// artifact each build step stages, and an Android SDK is present. Tests
/// break one later step and run the script with [run].
({String root, Future<ProcessResult> Function(List<String>) run})
_realProductBuild(
  Directory sandbox,
  String product,
  String appDir,
  String system,
) {
  final root = p.join(sandbox.path, '$product-real');
  final app = p.join(root, 'app', appDir);
  for (final platform in ['linux', 'android']) {
    Directory(p.join(app, platform)).createSync(recursive: true);
  }
  final script = File(p.join(root, 'scripts', 'build.sh'))
    ..parent.createSync(recursive: true);
  File(
    p.join(_repositoryRoot().path, product, 'scripts', 'build.sh'),
  ).copySync(script.path);
  final packager = File(p.join(root, 'scripts', 'package-linux.sh'))
    ..writeAsStringSync('#!/usr/bin/env bash\n');
  final sdk = p.join(sandbox.path, 'android-sdk');
  Directory(p.join(sdk, 'platforms')).createSync(recursive: true);

  final host = _fakeHost(sandbox, system);
  final bin = p.join(sandbox.path, 'fake-bin');
  File(p.join(bin, 'flutter')).writeAsStringSync(r'''#!/usr/bin/env bash
[[ "$1" == build ]] || exit 0
case "$2" in
  linux) mkdir -p build/linux/x64/release/bundle ;;
  apk) mkdir -p build/app/outputs/flutter-apk
       touch build/app/outputs/flutter-apk/app-release.apk ;;
esac
''');
  File(p.join(bin, 'dart')).writeAsStringSync(r'''#!/usr/bin/env bash
[[ "$1" == compile ]] || exit 0
while [[ $# -gt 0 && "$1" != -o ]]; do shift; done
touch "$2"
''');
  Process.runSync('chmod', [
    '+x',
    packager.path,
    p.join(bin, 'flutter'),
    p.join(bin, 'dart'),
  ]);

  return (
    root: root,
    run: (arguments) => Process.run(
      'bash',
      [script.path, ...arguments],
      environment: {
        ...Platform.environment,
        ...host.environment,
        'ANDROID_SDK_ROOT': sdk,
      },
    ),
  );
}

/// A fake host on PATH: `uname -s` reports [system], and `open` records
/// its arguments instead of opening Finder.
({Map<String, String> environment, List<String> Function() opened}) _fakeHost(
  Directory root,
  String system,
) {
  final bin = Directory(p.join(root.path, 'fake-bin'))..createSync();
  final log = File(p.join(root.path, 'open.log'));
  void writeTool(String name, String body) {
    final tool = File(p.join(bin.path, name))..writeAsStringSync(body);
    Process.runSync('chmod', ['+x', tool.path]);
  }

  writeTool('uname', '''#!/usr/bin/env bash
if [[ "\${1:-}" == -s ]]; then echo $system; else echo fake; fi
''');
  writeTool('open', '''#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${log.path}"
''');

  return (
    environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
    opened: () => log.existsSync()
        ? log.readAsLinesSync().where((line) => line.isNotEmpty).toList()
        : <String>[],
  );
}

/// Fake product scripts: planchette and seance build (each emits a dist
/// marker and records its args in mode.marker), seance fails on demand via
/// FAKE_BUILD_FAIL, and poltergeist has no script at all.
void _writeProducts(Directory root) {
  void writeScript(String product, String body) {
    final script = File(p.join(root.path, product, 'scripts', 'build.sh'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(body);
    Process.runSync('chmod', ['+x', script.path]);
  }

  writeScript('planchette', '''#!/usr/bin/env bash
set -euo pipefail
dist="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)/dist"
printf '%s' "\$*" > "\$(dirname "\${BASH_SOURCE[0]}")/../mode.marker"
mkdir -p "\$dist"
touch "\$dist/planchette-artifact"
''');
  writeScript('seance', '''#!/usr/bin/env bash
set -euo pipefail
[[ "\${FAKE_BUILD_FAIL:-}" == seance ]] && exit 1
printf '%s' "\${HAUNTWARE_BUILD_ORCHESTRATED:-}" > "\$(dirname "\${BASH_SOURCE[0]}")/../orchestrated.marker"
dist="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)/dist"
printf '%s' "\$*" > "\$(dirname "\${BASH_SOURCE[0]}")/../mode.marker"
mkdir -p "\$dist"
touch "\$dist/seance-artifact"
''');
}

Directory _repositoryRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File(p.join(candidate.path, 'scripts', 'build.sh')).existsSync() &&
        File(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
      return candidate;
    }

    final parent = candidate.parent;
    if (p.equals(parent.path, candidate.path)) {
      throw StateError('repository root not found from ${Directory.current}');
    }
    candidate = parent;
  }
}
