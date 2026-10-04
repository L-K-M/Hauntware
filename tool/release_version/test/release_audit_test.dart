@TestOn('posix')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _driverPath = 'scripts/refresh-seance-release-audit.sh';
const _recordPath = 'poltergeist/docs/PORTS.md';
const _originalRecord = 'original audit\n';
const _updatedRecord = 'updated audit\n';
const _successExitCode = 0;
const _failureExitCode = 1;
const _usageExitCode = 64;
const _fixtureIdentity = {
  'GIT_AUTHOR_NAME': 'Release audit fixture',
  'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
  'GIT_COMMITTER_NAME': 'Release audit fixture',
  'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
};

void main() {
  late Directory sandbox;
  late Directory repository;
  late String originalHead;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('hauntware-release-audit-');
    repository = Directory(p.join(sandbox.path, 'repository'))..createSync();

    _write(repository, _driverPath, File(_driverPath).readAsStringSync());
    _write(repository, _recordPath, _originalRecord);
    _write(repository, 'unrelated.txt', 'preserved\n');
    _write(repository, 'poltergeist/scripts/audit-seance-pin.sh', '''
#!/usr/bin/env bash
set -euo pipefail
[[ "\$*" == --write-record ]] || exit $_usageExitCode
case "\$FAKE_AUDIT_MODE" in
  changed) printf '%s' '$_updatedRecord' > docs/PORTS.md ;;
  current) ;;
  failed) exit $_failureExitCode ;;
esac
''');

    _git(repository, ['init', '--quiet']);
    _git(repository, ['add', '.']);
    _git(repository, ['commit', '--quiet', '-m', 'Create audit fixture']);
    originalHead = _git(repository, [
      'rev-parse',
      'HEAD',
    ]).stdout.toString().trim();
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test(
    'commits a refreshed audit before the release tag can be created',
    () async {
      final result = await _runDriver(repository, sandbox, _AuditMode.changed);

      expect(
        result.exitCode,
        _successExitCode,
        reason: result.stderr.toString(),
      );
      expect(
        _git(repository, ['rev-parse', 'HEAD']).stdout.toString().trim(),
        isNot(originalHead),
      );
      expect(
        _git(repository, ['log', '-1', '--format=%s']).stdout,
        contains('Refresh Séance source audit record'),
      );
      expect(
        _git(repository, [
          'diff-tree',
          '--no-commit-id',
          '--name-only',
          '-r',
          'HEAD',
        ]).stdout,
        '$_recordPath\n',
      );
      expect(_git(repository, ['status', '--porcelain']).stdout, isEmpty);
      expect(
        File(p.join(repository.path, _recordPath)).readAsStringSync(),
        _updatedRecord,
      );
    },
  );

  test('does not create a commit when the audit is current', () async {
    final result = await _runDriver(repository, sandbox, _AuditMode.current);

    expect(result.exitCode, _successExitCode, reason: result.stderr.toString());
    expect(
      _git(repository, ['rev-parse', 'HEAD']).stdout.toString().trim(),
      originalHead,
    );
    expect(_git(repository, ['status', '--porcelain']).stdout, isEmpty);
  });

  test('stops without a commit when audit generation fails', () async {
    final result = await _runDriver(repository, sandbox, _AuditMode.failed);

    expect(result.exitCode, _failureExitCode);
    expect(
      _git(repository, ['rev-parse', 'HEAD']).stdout.toString().trim(),
      originalHead,
    );
    expect(
      File(p.join(repository.path, _recordPath)).readAsStringSync(),
      _originalRecord,
    );
  });

  test('refuses pre-existing changes before refreshing the audit', () async {
    _write(repository, 'unrelated.txt', 'user work\n');
    final result = await _runDriver(repository, sandbox, _AuditMode.changed);

    expect(result.exitCode, _failureExitCode);
    expect(result.stderr, contains('clean working tree'));
    expect(
      _git(repository, ['rev-parse', 'HEAD']).stdout.toString().trim(),
      originalHead,
    );
    expect(
      File(p.join(repository.path, _recordPath)).readAsStringSync(),
      _originalRecord,
    );
    expect(
      File(p.join(repository.path, 'unrelated.txt')).readAsStringSync(),
      'user work\n',
    );
  });
}

enum _AuditMode { changed, current, failed }

Future<ProcessResult> _runDriver(
  Directory repository,
  Directory caller,
  _AuditMode mode,
) => Process.run(
  'bash',
  [p.join(repository.path, _driverPath)],
  workingDirectory: caller.path,
  environment: {
    ...Platform.environment,
    ..._fixtureIdentity,
    'FAKE_AUDIT_MODE': mode.name,
  },
);

ProcessResult _git(Directory repository, List<String> arguments) {
  final result = Process.runSync(
    'git',
    ['-C', repository.path, ...arguments],
    environment: {...Platform.environment, ..._fixtureIdentity},
  );
  expect(result.exitCode, _successExitCode, reason: result.stderr.toString());
  return result;
}

void _write(Directory repository, String path, String contents) {
  File(p.join(repository.path, path))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
}
