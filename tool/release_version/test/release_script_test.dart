@TestOn('posix')
library;

// Release tooling stays outside the shipped applications.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repository_root.dart';

void main() {
  late Directory sandbox;
  late File fakeEngine;
  late File fakeGit;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'hauntware-release-script-test-',
    );
    fakeEngine = File(p.join(sandbox.path, 'fake-release'));
    fakeEngine.writeAsStringSync('''#!/usr/bin/env bash
set -euo pipefail

if [[ "\$1" == "--capabilities" ]]; then
  [[ -n "\${FAKE_ENGINE_LOG:-}" ]] && printf 'capabilities\\n' >> "\$FAKE_ENGINE_LOG"
  case "\${FAKE_CAPABILITIES:-RELEASE_PRE_TAG}" in
    reject) exit 1 ;;
    *) printf '%s\\n' "\${FAKE_CAPABILITIES:-RELEASE_PRE_TAG}" ;;
  esac
  exit 0
fi

if [[ "\${FAKE_POST_BUMP_MODE:-skip}" == failSynchronization ]]; then
  cd "\$FAKE_POST_BUMP_ROOT"
  RELEASE_DART_BIN=false RELEASE_NEW_VERSION=0.2.0 bash -c "\$RELEASE_POST_BUMP"
  printf 'post-ran\\n'
  exit 0
fi
if [[ "\${FAKE_POST_BUMP_MODE:-skip}" == succeedSynchronization ]]; then
  cd "\$FAKE_POST_BUMP_ROOT"
  RELEASE_DART_BIN="\$DART_BIN" RELEASE_NEW_VERSION=0.2.0 bash -c "\$RELEASE_POST_BUMP"
  printf 'post-ran\\n'
  exit 0
fi

printf 'pubspecs=%s\n' "\$RELEASE_PUBSPECS"
printf 'regex=%s\n' "\$RELEASE_VERSION_REGEX"
printf 'sign=%s\n' "\${RELEASE_SIGN_TAG:-}"
printf 'post=%s\n' "\$RELEASE_POST_BUMP"
printf 'pretag=%s\n' "\${RELEASE_PRE_TAG:-}"
printf 'args=%s\n' "\$*"
printf 'cwd=%s\n' "\$PWD"
''');
    fakeGit = File(p.join(sandbox.path, 'git'));
    fakeGit.writeAsStringSync(r'''#!/usr/bin/env bash
if [[ "$1" == "-C" && "$3" == "tag" && "$4" == "--list" ]]; then
  [[ "${FAKE_GIT_FAILURE:-none}" == localTags ]] && exit 2
  [[ -n "${FAKE_RELEASE_TAGS:-}" ]] && printf '%s\n' "$FAKE_RELEASE_TAGS"
  exit 0
fi
if [[ "$1" == "-C" && "$3" == "ls-remote" ]]; then
  [[ "${FAKE_GIT_FAILURE:-none}" == remoteTags ]] && exit 2
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    printf '0000000000000000000000000000000000000000\trefs/tags/%s\n' "$tag"
  done <<< "${FAKE_REMOTE_TAGS:-}"
  exit 0
fi
echo "fake git: unexpected invocation: $*" >&2
exit 1
''');
    Process.runSync('chmod', ['+x', fakeEngine.path, fakeGit.path]);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('publishes the suite lockstep set to the engine', () async {
    final result = await _runRelease(fakeEngine, [
      '2099.99.99',
      '--push',
    ], git: fakeGit);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final pubspecs = _line(result, 'pubspecs=');
    // The suite manifest leads — the engine reads the version from it.
    expect(pubspecs, startsWith('pubspecs=pubspec.yaml '));
    for (final expected in [
      'planchette/app/planchette_app/pubspec.yaml',
      'planchette/packages/planchette_core/pubspec.yaml',
      'seance/app/seance_app/pubspec.yaml',
      'seance/packages/seance_sync_server/pubspec.yaml',
      'poltergeist/app/poltergeist_app/pubspec.yaml',
      'poltergeist/packages/poltergeist_bench/pubspec.yaml',
      'poltergeist/packages/poltergeist_core/pubspec.yaml',
      // The live bench compat shim bumps in lockstep with the suite.
      'poltergeist/tool/bench/pubspec.yaml',
    ]) {
      expect(pubspecs, contains(expected), reason: expected);
    }
    // Not owned: vendored forks and the unversioned workspace roots.
    expect(pubspecs, isNot(contains('third_party')));
    expect(pubspecs, isNot(contains('_workspace')));
    expect(pubspecs, isNot(contains('planchette/pubspec.yaml')));
    expect(pubspecs, isNot(contains('seance/pubspec.yaml')));
    expect(pubspecs, isNot(contains('poltergeist/pubspec.yaml')));

    // The post-bump hook delegates to the version tool — no sed inline.
    expect(result.stdout, contains('post-bump --version'));
    expect(
      result.stdout,
      contains('tool/release_version/bin/release_version.dart'),
    );
    expect(result.stdout, contains(RegExp('^sign=\$', multiLine: true)));
    expect(result.stdout, contains('args=2099.99.99 --push'));
  });

  test('rejects an invalid version before invoking the engine', () async {
    final result = await _runRelease(fakeEngine, [
      '0.2.0-alpha1',
    ], git: fakeGit);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('invalid release version'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('rejects a target behind a prior release tag', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.98'],
      git: fakeGit,
      priorTags: 'v2099.99.99',
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('prior tag v2099.99.99'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('rejects a target behind a remote release tag', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.98'],
      git: fakeGit,
      remoteTags: 'v2099.99.99',
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('prior tag v2099.99.99'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('fails closed when local release tags cannot be read', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      gitFailure: _GitFailure.localTags,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('could not read local release tags'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('fails closed when remote release tags cannot be read', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      gitFailure: _GitFailure.remoteTags,
    );

    expect(result.exitCode, isNot(0));
    expect(
      result.stderr,
      contains("could not read release tags from 'origin'"),
    );
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('stops before the engine when pubspec discovery fails', () async {
    final fakeDart = File(p.join(sandbox.path, 'fake-dart'))
      ..writeAsStringSync(r'''#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *pubspecs)
    printf 'fixture: pubspec discovery failed\n' >&2
    exit 1 ;;
esac
''');
    Process.runSync('chmod', ['+x', fakeDart.path]);
    final root = findRepositoryRoot();
    final result = await Process.run(
      'bash',
      [p.join(root.path, 'scripts/release.sh'), '2099.99.99'],
      workingDirectory: sandbox.path,
      environment: {
        ...Platform.environment,
        'DART_BIN': fakeDart.path,
        'LKM_RELEASE_BIN': fakeEngine.path,
      },
    );

    expect(result.exitCode, isNot(0));
    expect(result.stdout, isNot(contains('args=')));
    expect(result.stderr, contains('fixture: pubspec discovery failed'));
  });

  test('post-bump stops when app metadata synchronization fails', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      postBumpMode: _PostBumpMode.failSynchronization,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stdout, isNot(contains('post-ran')));
  });

  test(
    'post-bump pins owned packages in locks and marks the READMEs',
    () async {
      _writeLockFixture(sandbox);

      final result = await _runRelease(
        fakeEngine,
        ['2099.99.99'],
        git: fakeGit,
        postBumpMode: _PostBumpMode.succeedSynchronization,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('post-ran'));

      // Owned path-pinned names move to the new version in every lock the
      // hook covers; hosted entries and unowned names stay put.
      expect(_lockedVersions(sandbox, 'planchette/pubspec.lock'), {
        'planchette_core': '0.2.0',
      });
      expect(_lockedVersions(sandbox, 'seance/app/seance_app/pubspec.lock'), {
        'planchette_core': '0.2.0',
        'seance_core': '0.2.0',
        'xterm': '4.0.0+seance.1',
      });
      // The live bench lock rewrites like every other managed lock.
      expect(_lockedVersions(sandbox, 'poltergeist/tool/bench/pubspec.lock'), {
        'poltergeist_m0_bench': '0.2.0',
        'seance_core': '0.2.0',
      });
      // The child README markers follow the release.
      expect(
        File(p.join(sandbox.path, 'seance/README.md')).readAsStringSync(),
        contains('<!-- version -->0.2.0<!-- /version -->'),
      );
    },
  );

  test('wires the pre-tag audit hook into the engine', () async {
    final result = await _runRelease(fakeEngine, ['2099.99.99'], git: fakeGit);

    expect(result.exitCode, 0, reason: result.stderr as String);
    // The audit driver is a dedicated root script; the stub hands it the
    // configured Dart executable through DART_EXECUTABLE.
    final pretag = _line(result, 'pretag=');
    expect(pretag, contains('scripts/refresh-seance-release-audit.sh'));
    expect(pretag, contains('DART_EXECUTABLE'));
    expect(pretag, contains('RELEASE_DART_BIN'));
    // An actual release probes the engine before letting it mutate.
    final engineLog = _engineLog(sandbox);
    expect(
      engineLog.existsSync(),
      isTrue,
      reason: 'the stub did not probe the engine',
    );
    expect(engineLog.readAsStringSync(), contains('capabilities'));
  });

  test('accepts RELEASE_PRE_TAG among other capabilities', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      capabilities: 'RELEASE_POST_BUMP\nRELEASE_PRE_TAG\nRELEASE_X',
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('args=2099.99.99'));
  });

  test('fails closed when the engine rejects --capabilities', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      capabilities: 'reject',
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('RELEASE_PRE_TAG'));
    expect(result.stdout, isNot(contains('args=')));
  });

  test('fails closed when the engine lacks RELEASE_PRE_TAG', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      capabilities: 'RELEASE_POST_BUMP',
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('RELEASE_PRE_TAG'));
    expect(result.stdout, isNot(contains('args=')));
  });

  for (final arguments in [
    ['--help'],
    ['--version'],
    ['--check'],
  ]) {
    test('${arguments.single} skips the capability probe', () async {
      final result = await _runRelease(
        fakeEngine,
        arguments,
        git: fakeGit,
        capabilities: 'reject',
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('args=${arguments.single}'));
      expect(_engineLog(sandbox).existsSync(), isFalse);
    });
  }

  test('runs the engine from the repository root', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      invocationDirectory: _InvocationDirectory.caller,
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('cwd=${findRepositoryRoot().path}\n'));
  });

  for (final product in ['planchette', 'seance', 'poltergeist']) {
    test('$product release.sh forwards the whole-suite release', () async {
      final root = findRepositoryRoot();
      final result = await Process.run(
        'bash',
        [p.join(root.path, product, 'scripts/release.sh'), '--help'],
        environment: {
          ...Platform.environment,
          'LKM_RELEASE_BIN': fakeEngine.path,
          'PATH': '${fakeGit.parent.path}:${Platform.environment['PATH']}',
        },
        workingDirectory: sandbox.path,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('args=--help'));
      expect(result.stdout, contains('cwd=${root.path}'));
    });
  }
}

Future<ProcessResult> _runRelease(
  File engine,
  List<String> arguments, {
  required File git,
  _GitFailure gitFailure = _GitFailure.none,
  _InvocationDirectory invocationDirectory = _InvocationDirectory.repository,
  _PostBumpMode postBumpMode = _PostBumpMode.skip,
  String capabilities = '',
  String priorTags = '',
  String remoteTags = '',
}) {
  final root = findRepositoryRoot();
  return Process.run(
    'bash',
    [p.join(root.path, 'scripts/release.sh'), ...arguments],
    workingDirectory: switch (invocationDirectory) {
      _InvocationDirectory.caller => git.parent.path,
      _InvocationDirectory.repository => root.path,
    },
    environment: {
      ...Platform.environment,
      'FAKE_CAPABILITIES': capabilities,
      'FAKE_ENGINE_LOG': _engineLog(git.parent).path,
      'FAKE_GIT_FAILURE': gitFailure.name,
      'FAKE_POST_BUMP_MODE': postBumpMode.name,
      'FAKE_POST_BUMP_ROOT': git.parent.path,
      'FAKE_REMOTE_TAGS': remoteTags,
      'FAKE_RELEASE_TAGS': priorTags,
      'LKM_RELEASE_BIN': engine.path,
      'DART_BIN': Platform.resolvedExecutable,
      'PATH': '${git.parent.path}:${Platform.environment['PATH']}',
    },
  );
}

enum _GitFailure { localTags, none, remoteTags }

enum _InvocationDirectory { caller, repository }

enum _PostBumpMode { skip, failSynchronization, succeedSynchronization }

/// A repository shaped like the hook sees it at post-bump time (cwd =
/// repository root): owned pubspecs at the old version, locks across the
/// three trees pinning old versions, the live bench lock, a vendored
/// lock entry, and a child README marker. App pubspecs are absent on
/// purpose — post-bump skips missing product files.
void _writeLockFixture(Directory root) {
  void write(String path, String contents) {
    File(p.join(root.path, path))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  String pathEntry(String name, String directory, String version) =>
      '''
  $name:
    dependency: "direct main"
    description:
      path: "../../$directory"
      relative: true
    source: path
    version: "$version"
''';

  write(
    'planchette/packages/planchette_core/pubspec.yaml',
    'name: planchette_core\nversion: 0.1.0\n',
  );
  write(
    'seance/packages/seance_core/pubspec.yaml',
    'name: seance_core\nversion: 0.1.0\n',
  );
  write(
    'poltergeist/packages/poltergeist_bench/pubspec.yaml',
    'name: poltergeist_m0_bench\nversion: 0.1.0\n',
  );
  write(
    'poltergeist/tool/bench/pubspec.yaml',
    'name: poltergeist_m0_bench_compat\nversion: 0.1.0\n',
  );
  write(
    'planchette/pubspec.lock',
    'packages:\n'
        '${pathEntry('planchette_core', 'packages/planchette_core', '0.1.0')}',
  );
  write(
    'seance/app/seance_app/pubspec.lock',
    'packages:\n'
        '${pathEntry('planchette_core', 'planchette/packages/planchette_core', '0.1.0')}'
        '${pathEntry('seance_core', 'seance/packages/seance_core', '0.1.0')}'
        '${pathEntry('xterm', 'seance/third_party/xterm', '4.0.0+seance.1')}',
  );
  write(
    'poltergeist/tool/bench/pubspec.lock',
    'packages:\n'
        '${pathEntry('poltergeist_m0_bench', 'packages/poltergeist_bench', '0.1.0')}'
        '${pathEntry('seance_core', 'seance/packages/seance_core', '0.1.0')}',
  );
  write(
    'seance/README.md',
    'Latest: v<!-- version -->0.1.0<!-- /version -->\n',
  );
}

Map<String, String> _lockedVersions(Directory root, String path) {
  final entry = RegExp(r'^  (\w+):$');
  final version = RegExp(r'^    version: "([^"]*)"$');
  final versions = <String, String>{};
  String? current;
  for (final line in File(p.join(root.path, path)).readAsLinesSync()) {
    final name = entry.firstMatch(line)?[1];
    if (name != null) current = name;
    final locked = version.firstMatch(line)?[1];
    if (locked != null && current != null) versions[current] = locked;
  }
  return versions;
}

File _engineLog(Directory sandbox) =>
    File(p.join(sandbox.path, 'engine-queries.log'));

String _line(ProcessResult result, String prefix) => (result.stdout as String)
    .split('\n')
    .firstWhere((line) => line.startsWith(prefix), orElse: () => '');
