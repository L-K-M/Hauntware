// Release tooling stays outside the shipped application.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherCommit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late Directory sandbox;
  late File fakeDart;
  late File fakeGit;
  late File dartLog;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-finalize-script-test-',
    );
    dartLog = File(p.join(sandbox.path, 'dart.log'));
    fakeDart = File(p.join(sandbox.path, 'fake-dart'))
      ..writeAsStringSync('''#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FAKE_DART_LOG"
''');
    fakeGit = File(p.join(sandbox.path, 'fake-git'))
      ..writeAsStringSync('''#!/usr/bin/env bash
if [[ "\${1:-}" == "-C" ]]; then
  shift 2
fi
case "\${1:-}" in
  status)
    printf '%s' "\${FAKE_GIT_STATUS:-}"
    ;;
  rev-parse)
    if [[ "\${*: -1}" == "HEAD" ]]; then
      printf '%s\n' "\${FAKE_GIT_HEAD:-$_commit}"
    else
      printf '%s\n' "\${FAKE_GIT_TAG:-$_commit}"
    fi
    ;;
  *)
    printf 'unexpected fake Git call: %s\n' "\$*" >&2
    exit 2
    ;;
esac
''');
    for (final executable in [fakeDart, fakeGit]) {
      final result = Process.runSync('chmod', ['+x', executable.path]);
      expect(result.exitCode, 0, reason: result.stderr as String);
    }
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  Future<ProcessResult> run({Map<String, String> environment = const {}}) {
    return Process.run(
      'bash',
      [
        'scripts/finalize-release.sh',
        '--repository',
        'L-K-M/Poltergeist',
        '--tag',
        'v0.1.0',
        '--fingerprint',
        '0123456789ABCDEF0123456789ABCDEF01234567',
      ],
      environment: {
        ...Platform.environment,
        'DART_BIN': fakeDart.path,
        'GIT_BIN': fakeGit.path,
        'FAKE_DART_LOG': dartLog.path,
        ...environment,
      },
    );
  }

  test('runs finalization only from the exact clean tag', () async {
    final result = await run();

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(dartLog.readAsStringSync(), contains('--tag v0.1.0'));
  });

  test('rejects a dirty invoking checkout', () async {
    final result = await run(
      environment: const {'FAKE_GIT_STATUS': ' M tool/release_finalize\n'},
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('clean tagged checkout'));
    expect(dartLog.existsSync(), isFalse);
  });

  test('rejects an invoking checkout at another commit', () async {
    final result = await run(environment: const {'FAKE_GIT_TAG': _otherCommit});

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('exact tagged commit'));
    expect(dartLog.existsSync(), isFalse);
  });
}
