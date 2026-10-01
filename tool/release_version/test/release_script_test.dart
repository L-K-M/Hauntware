import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const primaryFingerprint = '0123456789ABCDEF0123456789ABCDEF01234567';
  late Directory sandbox;
  late File fakeEngine;
  late File fakeGit;
  late File fakeGitLog;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-script-test-',
    );
    fakeEngine = File(p.join(sandbox.path, 'fake-release'));
    fakeEngine.writeAsStringSync('''#!/usr/bin/env bash
if [[ "\${1:-}" == "--check" ]]; then
  if [[ "\${FAKE_RELEASE_FEATURE:-supported}" == "supported" &&
        "\${RELEASE_SIGN_TAG:-}" == "required" ]]; then
    printf '  tag mode:  signed (required)\n'
  else
    printf 'tag mode:  annotated\n'
  fi
  exit 0
fi
printf 'pubspecs=%s\n' "\$RELEASE_PUBSPECS"
printf 'regex=%s\n' "\$RELEASE_VERSION_REGEX"
printf 'post=%s\n' "\$RELEASE_POST_BUMP"
printf 'sign=%s\n' "\${RELEASE_SIGN_TAG:-}"
printf 'args=%s\n' "\$*"
''');
    Process.runSync('chmod', ['+x', fakeEngine.path]);
    fakeGitLog = File(p.join(sandbox.path, 'git.log'));
    fakeGit = File(p.join(sandbox.path, 'fake-git'));
    fakeGit.writeAsStringSync('''#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FAKE_GIT_LOG"
if [[ "\${1:-}" == "-C" ]]; then
  shift 2
fi
case "\${1:-}" in
  config)
    printf '%s\n' "\${FAKE_GIT_FORMAT:-openpgp}"
    ;;
  verify-tag)
    printf '[GNUPG:] VALIDSIG AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 2026-09-02 0 0 4 0 1 10 00 %s\n' "\${FAKE_GIT_PRIMARY_FINGERPRINT:-$primaryFingerprint}" >&2
    ;;
  tag)
    ;;
  *)
    printf 'unexpected fake Git call: %s\n' "\$*" >&2
    exit 2
    ;;
esac
''');
    Process.runSync('chmod', ['+x', fakeGit.path]);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  Future<ProcessResult> runRelease(
    File engine,
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) {
    return Process.run(
      'bash',
      ['scripts/release.sh', ...arguments],
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'LKM_RELEASE_BIN': engine.path,
        'GIT_BIN': fakeGit.path,
        'FAKE_GIT_LOG': fakeGitLog.path,
        'POLTERGEIST_RELEASE_FINGERPRINT': primaryFingerprint,
        ...environment,
      },
    );
  }

  test('validates and forwards a supported version family', () async {
    final result = await runRelease(fakeEngine, ['0.2.0-beta2', '--push']);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('tool/bench/pubspec.yaml'));
    expect(result.stdout, contains('app/poltergeist_app/pubspec.yaml'));
    expect(result.stdout, contains('release_version/bin/release_version.dart'));
    expect(result.stdout, contains('    sync'));
    expect(result.stdout, contains('sign=required'));
    expect(result.stdout, contains('args=0.2.0-beta2 --push'));
    expect(fakeGitLog.readAsStringSync(), contains('tag -s'));
    expect(fakeGitLog.readAsStringSync(), contains('verify-tag --raw'));
    expect(fakeGitLog.readAsStringSync(), contains('tag -d'));
  });

  test('rejects an engine without required signed-tag mode', () async {
    final result = await runRelease(
      fakeEngine,
      ['0.2.0'],
      environment: const {'FAKE_RELEASE_FEATURE': 'unsupported'},
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('signed-tag support'));
    expect(result.stdout, isNot(contains('args=0.2.0')));
  });

  test('rejects a non-OpenPGP Git signing format', () async {
    final result = await runRelease(
      fakeEngine,
      ['0.2.0'],
      environment: const {'FAKE_GIT_FORMAT': 'ssh'},
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('OpenPGP'));
    expect(result.stdout, isNot(contains('args=0.2.0')));
  });

  test('requires an independent primary fingerprint', () async {
    final result = await runRelease(
      fakeEngine,
      ['0.2.0'],
      environment: const {'POLTERGEIST_RELEASE_FINGERPRINT': ''},
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('40-hex OpenPGP primary fingerprint'));
    expect(result.stdout, isNot(contains('args=0.2.0')));
  });

  test('rejects a signing key that differs from the fingerprint', () async {
    final result = await runRelease(
      fakeEngine,
      ['0.2.0'],
      environment: const {
        'FAKE_GIT_PRIMARY_FINGERPRINT':
            'FEDCBA9876543210FEDCBA9876543210FEDCBA98',
      },
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('signed with FEDCBA'));
    expect(result.stdout, isNot(contains('args=0.2.0')));
    expect(fakeGitLog.readAsStringSync(), contains('tag -d'));
  });

  test('rejects an invalid version before invoking the engine', () async {
    final result = await runRelease(fakeEngine, ['0.2.0-alpha1']);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('invalid release version'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('rejects a version-code downgrade before invoking the engine', () async {
    final result = await runRelease(fakeEngine, ['0.0.99']);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('older than 0.1.0'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('checks the current version before a no-argument release', () async {
    final result = await runRelease(fakeEngine, const []);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, startsWith('0.1.0+10099 synchronized'));
    expect(result.stdout, contains('args=\n'));
  });

  test('Linux packaging uses the shared prerelease grammar', () {
    final source = File('scripts/package-linux.sh').readAsStringSync();

    expect(source, contains('release_version.dart'));
    expect(source, contains(r'validate --version "$VERSION"'));
    expect(source, contains(r'debian-version --version "$VERSION"'));
    expect(source, isNot(contains(r'DEB_VERSION="$VERSION-1"')));
    expect(source, isNot(contains(r'^[0-9]+\.[0-9]+\.[0-9]+$')));
  });

  test('Linux packaging accepts a spaced Dart executable path', () async {
    final tools = Directory(p.join(sandbox.path, 'tool directory'))
      ..createSync();
    final dart = File(p.join(tools.path, 'fake dart'))
      ..writeAsStringSync('''#!/usr/bin/env bash
if [[ "\$*" == *"debian-version"* ]]; then
  printf '0.1.0-1\n'
else
  printf '0.1.0+10099\n'
fi
''');
    final readelf = File(p.join(tools.path, 'readelf'))
      ..writeAsStringSync('''#!/usr/bin/env bash
if [[ "\${1:-}" == "-h" ]]; then
  printf '  Machine: Advanced Micro Devices X86-64\n'
fi
''');
    for (final executable in [dart, readelf]) {
      final chmod = Process.runSync('chmod', ['+x', executable.path]);
      expect(chmod.exitCode, 0, reason: chmod.stderr as String);
    }
    final bundle = Directory(p.join(sandbox.path, 'bundle'))..createSync();
    Directory(p.join(bundle.path, 'lib')).createSync();
    File(p.join(bundle.path, 'poltergeist')).writeAsBytesSync(const [1]);

    final result = await Process.run(
      'bash',
      ['scripts/package-linux.sh', '--bundle', bundle.path, '--print-deps'],
      environment: {
        ...Platform.environment,
        'DART_BIN': dart.path,
        'PATH': '${tools.path}:${Platform.environment['PATH']}',
      },
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('Poltergeist 0.1.0-1'));
  });
}
