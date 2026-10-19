@TestOn('posix')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repository_root.dart';

const _cocoaPodsFiles = [
  'ios/Flutter/Debug.xcconfig',
  'ios/Flutter/Release.xcconfig',
  'ios/Runner.xcodeproj/project.pbxproj',
  'ios/Runner.xcworkspace/contents.xcworkspacedata',
  'ios/Podfile',
  'ios/Podfile.lock',
  'macos/Flutter/Flutter-Debug.xcconfig',
  'macos/Flutter/Flutter-Release.xcconfig',
  'macos/Runner.xcodeproj/project.pbxproj',
  'macos/Runner.xcworkspace/contents.xcworkspacedata',
  'macos/Podfile',
  'macos/Podfile.lock',
];

void main() {
  late Directory sandbox;
  late _BuildFixture fixture;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('seance-build-cleanup-');
    fixture = _BuildFixture(sandbox);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test(
    'successful repeated app builds clean config and retain artifacts',
    () async {
      for (var run = 0; run < 2; run++) {
        final result = await fixture.run(['app']);

        expect(result.exitCode, 0, reason: _output(result));
        fixture.expectRestored();
        fixture.expectBuildUsedGeneratedConfig();
        fixture.expectCachesRetained();
        expect(
          File(
            p.join(
              fixture.root,
              'dist',
              'Séance.app',
              'Contents',
              'Info.plist',
            ),
          ).readAsStringSync(),
          'fake app',
        );
      }
    },
  );

  test('preserves exact dirty bytes and existing untracked Podfiles', () async {
    // No Git repository exists in this fixture. Restoration must preserve the
    // actual working files, including their custom line endings and bytes.
    fixture.writeOriginal('ios/Flutter/Debug.xcconfig', [0, 255, 13, 10, 42]);
    for (final path in _cocoaPodsFiles.where(
      (path) => path.contains('Podfile'),
    )) {
      fixture.writeOriginal(path, 'developer-owned $path\r\n'.codeUnits);
    }

    final result = await fixture.run(['app', 'apk']);

    expect(result.exitCode, 0, reason: _output(result));
    fixture.expectRestored();
    fixture.expectBuildUsedGeneratedConfig();
    fixture.expectCachesRetained();
    expect(
      File(p.join(fixture.root, 'dist', 'seance.apk')).readAsStringSync(),
      'fake apk',
    );
  });

  for (final failure in ['pub', 'build']) {
    test(
      'restores source and removes generated Podfiles after $failure failure',
      () async {
        fixture.writeOriginal(
          'ios/Podfile',
          'untracked developer Podfile\n'.codeUnits,
        );

        final result = await fixture.run(['app'], failure: failure);

        expect(result.exitCode, isNot(0), reason: _output(result));
        expect(result.stdout, contains('app: FAILED'));
        fixture.expectRestored();
        fixture.expectCachesRetained();
        if (failure == 'build') fixture.expectBuildUsedGeneratedConfig();
      },
    );
  }

  test('APK-only build on Darwin also restores Apple config', () async {
    final result = await fixture.run(['apk']);

    expect(result.exitCode, 0, reason: _output(result));
    fixture.expectRestored();
    fixture.expectBuildUsedGeneratedConfig();
    fixture.expectCachesRetained();
    expect(
      File(p.join(fixture.root, 'dist', 'seance.apk')).readAsStringSync(),
      'fake apk',
    );
  });

  test('SIGTERM restores configuration and reports interruption', () async {
    final result = await fixture.run(['app'], failure: 'term');

    expect(result.exitCode, 143, reason: _output(result));
    fixture.expectRestored();
    fixture.expectCachesRetained();
  });

  test('cleanup failure fails the build and retains named backups', () async {
    fixture.failCleanup();

    final result = await fixture.run(['app']);

    expect(result.exitCode, isNot(0), reason: _output(result));
    expect(result.stderr, contains('Apple configuration cleanup failed'));
    final backup = sandbox.listSync().whereType<Directory>().singleWhere(
      (directory) =>
          p.basename(directory.path).startsWith('seance-apple-config.'),
    );
    expect(result.stderr, contains(backup.path));
    expect(
      File(
        p.join(backup.path, 'ios', 'Flutter', 'Debug.xcconfig'),
      ).readAsBytesSync(),
      orderedEquals(fixture.originalBytes('ios/Flutter/Debug.xcconfig')),
    );
  });

  for (final dangling in [false, true]) {
    test(
      'rejects ${dangling ? 'dangling' : 'existing'} config symlink before Flutter',
      () async {
        final target = File(p.join(sandbox.path, 'outside-config'));
        if (!dangling) target.writeAsStringSync('developer bytes');
        final link = Link(
          p.join(fixture.app, 'ios', 'Flutter', 'Debug.xcconfig'),
        );
        File(link.path).deleteSync();
        link.createSync(target.path);

        final result = await fixture.run(['app']);

        expect(result.exitCode, isNot(0), reason: _output(result));
        expect(result.stderr, contains('ios/Flutter/Debug.xcconfig'));
        expect(fixture.flutterLog.existsSync(), isFalse);
        expect(link.targetSync(), target.path);
        expect(target.existsSync(), !dangling);
        if (!dangling) expect(target.readAsStringSync(), 'developer bytes');
      },
    );
  }
}

String _output(ProcessResult result) => '${result.stdout}${result.stderr}';

class _BuildFixture {
  _BuildFixture(this.sandbox) {
    final script = File(p.join(root, 'scripts', 'build.sh'))
      ..parent.createSync(recursive: true);
    File(
      p.join(findRepositoryRoot().path, 'seance', 'scripts', 'build.sh'),
    ).copySync(script.path);
    for (final platform in ['ios', 'macos', 'android']) {
      Directory(p.join(app, platform)).createSync(recursive: true);
    }
    Directory(
      p.join(sandbox.path, 'sdk', 'platforms'),
    ).createSync(recursive: true);
    for (final path in _cocoaPodsFiles.where(
      (path) => !path.contains('Podfile'),
    )) {
      writeOriginal(path, 'developer config: $path\r\n'.codeUnits);
    }
    File(p.join(app, 'unrelated-source')).writeAsStringSync('keep source');
    _writeTool('uname', '#!/usr/bin/env bash\necho Darwin\n');
    _writeTool('pod', '#!/usr/bin/env bash\nexit 0\n');
    _writeTool('open', '#!/usr/bin/env bash\nexit 0\n');
    _writeTool('flutter', _fakeFlutter);
  }

  final Directory sandbox;
  final Map<String, List<int>> _originals = {};

  String get root => p.join(sandbox.path, 'seance');
  String get app => p.join(root, 'app', 'seance_app');
  String get _bin => p.join(sandbox.path, 'bin');
  File get flutterLog => File(p.join(sandbox.path, 'flutter.log'));

  void writeOriginal(String path, List<int> bytes) {
    final file = File(p.join(app, path))..parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    _originals[path] = List.of(bytes);
  }

  List<int> originalBytes(String path) => _originals[path]!;

  void failCleanup() {
    _writeTool('rm', r'''#!/usr/bin/env bash
for argument in "$@"; do
  [[ "$argument" != */ios/Podfile ]] || exit 1
done
exec /bin/rm "$@"
''');
  }

  Future<ProcessResult> run(List<String> arguments, {String failure = ''}) {
    return Process.run(
      'bash',
      [
        '-c',
        r'export FAKE_BUILD_PID=$$; exec bash "$@"',
        'seance-build-test',
        p.join(root, 'scripts', 'build.sh'),
        ...arguments,
      ],
      environment: {
        ...Platform.environment,
        'PATH': '$_bin:/usr/bin:/bin',
        'ANDROID_SDK_ROOT': p.join(sandbox.path, 'sdk'),
        'TMPDIR': sandbox.path,
        'FAKE_COCOAPODS_FILES': _cocoaPodsFiles.join('\n'),
        'FAKE_FAILURE': failure,
        'FAKE_LOG': flutterLog.path,
        'FAKE_BUILD_VERIFIED': p.join(sandbox.path, 'build-verified'),
      },
    );
  }

  void expectRestored() {
    for (final path in _cocoaPodsFiles) {
      final file = File(p.join(app, path));
      final expected = _originals[path];
      if (expected == null) {
        expect(
          FileSystemEntity.typeSync(file.path, followLinks: false),
          FileSystemEntityType.notFound,
          reason: '$path was generated by this build',
        );
      } else {
        expect(file.readAsBytesSync(), orderedEquals(expected), reason: path);
      }
    }
  }

  void expectBuildUsedGeneratedConfig() {
    expect(
      File(p.join(sandbox.path, 'build-verified')).readAsStringSync(),
      'yes',
    );
  }

  void expectCachesRetained() {
    expect(
      File(p.join(app, 'build', 'cache-marker')).readAsStringSync(),
      'keep cache',
    );
    expect(
      File(
        p.join(app, 'macos', 'Flutter', 'ephemeral', 'generated-marker'),
      ).readAsStringSync(),
      'keep generated',
    );
    expect(
      File(p.join(app, 'unrelated-source')).readAsStringSync(),
      'keep source',
    );
  }

  void _writeTool(String name, String content) {
    final tool = File(p.join(_bin, name))..parent.createSync(recursive: true);
    tool.writeAsStringSync(content);
    final result = Process.runSync('chmod', ['+x', tool.path]);
    if (result.exitCode != 0) {
      throw StateError('chmod failed: ${result.stderr}');
    }
  }
}

const _fakeFlutter = r'''#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_LOG"
if [[ "$1" == pub && "$2" == get ]]; then
  while IFS= read -r file; do
    mkdir -p "$(dirname "$file")"
    printf 'generated config\n' > "$file"
  done <<< "$FAKE_COCOAPODS_FILES"
  mkdir -p build macos/Flutter/ephemeral
  printf 'keep cache' > build/cache-marker
  printf 'keep generated' > macos/Flutter/ephemeral/generated-marker
  if [[ "$FAKE_FAILURE" == term ]]; then
    kill -TERM "$FAKE_BUILD_PID"
    exit 0
  fi
  [[ "$FAKE_FAILURE" != pub ]] || exit 23
elif [[ "$1" == build ]]; then
  while IFS= read -r file; do
    grep -qx 'generated config' "$file" || exit 96
  done <<< "$FAKE_COCOAPODS_FILES"
  printf yes > "$FAKE_BUILD_VERIFIED"
  [[ "$FAKE_FAILURE" != build ]] || exit 24
  case "$2" in
    macos)
      mkdir -p build/macos/Build/Products/Release/Seance.app/Contents
      printf 'fake app' > build/macos/Build/Products/Release/Seance.app/Contents/Info.plist
      ;;
    apk)
      mkdir -p build/app/outputs/flutter-apk
      printf 'fake apk' > build/app/outputs/flutter-apk/app-release.apk
      ;;
    *) exit 97 ;;
  esac
else
  exit 98
fi
''';
