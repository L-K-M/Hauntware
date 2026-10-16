// Contract tests for Klabautermann's integration legs in the root CI
// workflow (03 §11.3, §11.4, §11.6; 04 §12.1, CI row). The detector's
// entry-point guard runs here against throwaway git repositories, so its
// three outcomes (run the leg, skip it until the entry point is
// committed, fail once a committed entry point is gone) are checked
// without GitHub.
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The entry points later PRs commit, by the detector output that runs
/// their leg.
const _entries = {
  'fixture': 'klabautermann/test/integration/docker-compose.yml',
  'capture': 'klabautermann/test/integration/capture.sh',
  'frames': 'klabautermann/scripts/bench-frame-timing.sh',
};

const _detector = 'detect_klabautermann_integration';
const _integration = 'klabautermann_integration';
const _frameTiming = 'klabautermann_frame_timing';

/// The soak the integration job has to outlast (03 §11.4).
const _soakMinutes = 10;

void main() {
  late YamlMap workflow;
  late YamlMap jobs;
  late String guard;

  setUpAll(() async {
    final workspace = await Isolate.resolvePackageUri(
      Uri.parse('package:_klabautermann_workspace/'),
    );
    if (workspace == null) throw StateError('Workspace package is unresolved.');

    final path = workspace.resolve('../../.github/workflows/ci.yml');
    workflow = loadYaml(await File.fromUri(path).readAsString()) as YamlMap;
    jobs = workflow['jobs'] as YamlMap;
    guard = _step(jobs[_detector], id: 'entries')['run'] as String;
  });

  group('detector', () {
    test('selects the paths the fixture and engine build on', () {
      final filters =
          loadYaml(
                _step(jobs[_detector], id: 'changes')['with']['filters']
                    as String,
              )
              as YamlMap;
      expect(
        filters['integration'],
        containsAll([
          'klabautermann/**',
          'seance/packages/seance_core/lib/**',
          'seance/packages/seance_core/pubspec.yaml',
          'seance/packages/seance_protocol/lib/**',
          'seance/packages/seance_protocol/pubspec.yaml',
          'poltergeist/test/integration/check_config.dart',
          'poltergeist/test/integration/sshd-modern/Dockerfile',
          'poltergeist/test/integration/sshd-common/**',
          '.github/workflows/ci.yml',
        ]),
      );
    });

    test('filters pull requests only and checks every other event', () {
      final detector = jobs[_detector] as YamlMap;
      expect(
        _step(detector, id: 'changes')['if'],
        "github.event_name == 'pull_request'",
      );
      expect(
        _step(detector, id: 'entries')['if'],
        "github.event_name != 'pull_request' || "
        "steps.changes.outputs.integration == 'true'",
      );
      // The flags [_Repo.guard] runs the guard with.
      expect(_step(detector, id: 'entries')['shell'], 'bash');
      final checkout = _step(detector, uses: 'actions/checkout@');
      expect(checkout['with']['fetch-depth'], 0);
      for (final key in _entries.keys) {
        expect(detector['outputs'][key], '\${{ steps.entries.outputs.$key }}');
      }
    });

    test('checks the entry points the legs run', () {
      for (final path in _entries.values) {
        expect(guard, contains(path));
      }
      final integration = jobs[_integration] as YamlMap;
      expect(
        integration['defaults']['run']['working-directory'],
        'klabautermann',
      );
      expect(
        _runs(integration),
        containsAll(['test/integration/run.sh', 'test/integration/capture.sh']),
      );
      final frames = jobs[_frameTiming] as YamlMap;
      expect(frames['defaults']['run']['working-directory'], 'klabautermann');
      expect(_runs(frames), contains('scripts/bench-frame-timing.sh'));
    });
  });

  group('legs', () {
    test('integration runs on Ubuntu once the fixture or captures land', () {
      final job = jobs[_integration] as YamlMap;
      expect(job['needs'], _detector);
      expect(job['runs-on'], 'ubuntu-latest');
      expect(
        job['if'],
        "needs.$_detector.outputs.fixture == 'true' || "
        "needs.$_detector.outputs.capture == 'true'",
      );
      expect(
        _step(job, name: 'Run SSH integration fixture')['if'],
        "needs.$_detector.outputs.fixture == 'true'",
      );
      expect(
        _step(job, name: 'Run container shell and userland captures')['if'],
        "\${{ !cancelled() && needs.$_detector.outputs.capture == 'true' }}",
      );
      expect(job['continue-on-error'], isNull);
      expect(job['timeout-minutes'], greaterThan(_soakMinutes));
    });

    test('frame timing runs on main pushes and dispatch only', () {
      final job = jobs[_frameTiming] as YamlMap;
      expect(job['needs'], _detector);
      expect(
        job['if'],
        "github.event_name != 'pull_request' && "
        "needs.$_detector.outputs.frames == 'true'",
      );
      final flutter = _step(job, uses: 'subosito/flutter-action@');
      expect(flutter['with']['flutter-version'], r'${{ env.FLUTTER_VERSION }}');
      final measure = _step(job, name: 'Measure frame timing under Xvfb');
      expect(measure['env']['LIBGL_ALWAYS_SOFTWARE'], '1');
      expect(
        _step(job, name: 'Install Linux desktop and display toolchain')['run'],
        contains('xvfb'),
      );
    });

    test('main runs stay uncancelled', () {
      expect(
        workflow['concurrency']['cancel-in-progress'],
        r"${{ github.event_name == 'pull_request' }}",
      );
      for (final name in [_detector, _integration, _frameTiming]) {
        expect(
          (jobs[name] as YamlMap).containsKey('concurrency'),
          isFalse,
          reason: name,
        );
      }
    });

    test('the package job analyzes, formats and tests the fixture tools', () {
      final runs = _runs(jobs['klabautermann_dart'] as YamlMap);
      expect(runs, contains('dart analyze --fatal-infos test/integration'));
      expect(
        runs,
        contains(
          'dart format --output=none --set-exit-if-changed packages '
          'test/integration',
        ),
      );
      expect(runs, contains('dart test --reporter expanded test/integration'));
    });
  });

  group('entry-point guard', () {
    for (final event in ['push', 'pull_request']) {
      test(
        '$event skips every leg before its entry point is committed',
        () async {
          final repo = await _Repo.create();
          await repo.commit({'README.md': 'base'});
          if (event == 'pull_request') {
            await repo.mergeBranch('pr', [
              {'README.md': 'change'},
            ]);
          }

          final result = await repo.guard(guard);

          expect(result.exitCode, 0, reason: result.stdout);
          expect(result.outputs, {
            for (final key in _entries.keys) key: 'false',
          });
          for (final path in _entries.values) {
            expect(result.stdout, contains('::notice::$path'));
          }
        },
      );
    }

    for (final MapEntry(key: key, value: path) in _entries.entries) {
      test('runs the $key leg once its entry point is committed', () async {
        final repo = await _Repo.create();
        await repo.commit({path: 'entry'});

        final result = await repo.guard(guard);

        expect(result.exitCode, 0, reason: result.stdout);
        expect(result.outputs, {
          for (final other in _entries.keys)
            other: other == key ? 'true' : 'false',
        });
      });

      test('fails when the committed $key entry point is deleted', () async {
        final repo = await _Repo.create();
        await repo.commit({path: 'entry'});
        await repo.commit({path: null});

        final result = await repo.guard(guard);

        expect(result.exitCode, isNonZero);
        expect(result.stdout, contains('::error::Missing $path'));
        expect(result.outputs, isNot(contains(key)));
      });
    }

    test(
      'fails a pull request that deletes an entry point of its base',
      () async {
        final repo = await _Repo.create();
        await repo.commit({_entries['fixture']!: 'entry'});
        await repo.mergeBranch('pr', [
          {_entries['fixture']!: null},
        ]);

        final result = await repo.guard(guard);

        expect(result.exitCode, isNonZero);
        expect(
          result.stdout,
          contains('::error::Missing ${_entries['fixture']}'),
        );
      },
    );

    // The merge commit is both the test merge a pull request's run checks
    // out and the commit that lands the pull request on main.
    test(
      'skips an entry point a merged branch added and removed again',
      () async {
        final repo = await _Repo.create();
        await repo.commit({'README.md': 'base'});
        await repo.mergeBranch('pr', [
          {_entries['capture']!: 'entry'},
          {_entries['capture']!: null},
        ]);

        final result = await repo.guard(guard);

        expect(result.exitCode, 0, reason: result.stdout);
        expect(result.outputs['capture'], 'false');
      },
    );

    test('fails when a merge on the main line drops an entry point', () async {
      final path = _entries['fixture']!;
      final repo = await _Repo.create();
      await repo.commit({'README.md': 'base'});
      await repo.git(['branch', 'side']);
      await repo.commit({path: 'entry'});
      await repo.git(['checkout', '-q', 'side']);
      await repo.commit({'other.txt': 'side'});
      await repo.git(['checkout', '-q', 'main']);
      // The merge resolution drops the file its first parent has.
      await repo.git(['merge', '-q', '--no-commit', 'side']);
      await repo.commit({path: null});

      final result = await repo.guard(guard);

      expect(result.exitCode, isNonZero);
      expect(result.stdout, contains('::error::Missing $path'));
    });

    test('fails closed in a shallow clone', () async {
      final repo = await _Repo.create();
      await repo.commit({_entries['frames']!: 'entry'});
      await repo.commit({_entries['frames']!: null});
      final shallow = await repo.shallowClone();

      final result = await shallow.guard(guard);

      expect(result.exitCode, isNonZero);
      expect(result.stdout, contains('fetch-depth: 0'));
      expect(result.outputs, isEmpty);
    });

    test('fails closed when the history cannot be read', () async {
      // A repository without commits has no HEAD to read.
      final repo = await _Repo.create();

      final result = await repo.guard(guard);

      expect(result.exitCode, isNonZero);
      expect(result.stdout, contains('::error::Cannot read the history'));
    });
  });
}

/// The one step of [job] with this [id], [name] or `uses:` prefix.
YamlMap _step(Object? job, {String? id, String? name, String? uses}) {
  final steps = ((job as YamlMap)['steps'] as YamlList).cast<YamlMap>();
  return steps.singleWhere(
    (step) =>
        (id == null || step['id'] == id) &&
        (name == null || step['name'] == name) &&
        (uses == null || '${step['uses']}'.startsWith(uses)),
  );
}

/// Every `run:` script of [job], one per step.
List<String> _runs(YamlMap job) => [
  for (final step in (job['steps'] as YamlList).cast<YamlMap>())
    if (step['run'] case final String run) run.trim(),
];

typedef _GuardResult = ({
  int exitCode,
  String stdout,
  Map<String, String> outputs,
});

/// A throwaway git repository the guard runs in, with no user or system
/// git configuration.
final class _Repo {
  _Repo._(this._root, this.directory);

  final Directory _root;
  final Directory directory;

  static Future<_Repo> create() async {
    final root = await Directory.systemTemp.createTemp('klab-ci-guard-');
    addTearDown(() => root.delete(recursive: true));
    final repo = _Repo._(root, Directory('${root.path}/repo'));
    await repo.directory.create();
    await repo.git(['init', '-q', '-b', 'main']);
    return repo;
  }

  // Since git 2.47 the automatic maintenance after a commit or merge
  // detaches by default, so it can still be writing in .git while the
  // teardown deletes the directory. These repositories are thrown away,
  // so they need no maintenance at all.
  Map<String, String> get _environment => {
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    'HOME': _root.path,
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_COUNT': '2',
    'GIT_CONFIG_KEY_0': 'maintenance.auto',
    'GIT_CONFIG_VALUE_0': 'false',
    'GIT_CONFIG_KEY_1': 'gc.auto',
    'GIT_CONFIG_VALUE_1': '0',
  };

  /// Writes each file (null deletes it), commits, and returns the commit.
  Future<String> commit(Map<String, String?> files) async {
    for (final MapEntry(key: path, value: text) in files.entries) {
      final file = File('${directory.path}/$path');
      if (text == null) {
        await file.delete();
      } else {
        await file.create(recursive: true);
        await file.writeAsString(text);
      }
    }
    await git(['add', '-A']);
    await git(['commit', '-q', '--allow-empty', '-m', 'change']);
    return git(['rev-parse', 'HEAD']);
  }

  /// Commits each change set on a new branch [name] off HEAD and merges it
  /// back with a merge commit whose first parent is the old HEAD: how main
  /// lands a pull request, and how GitHub builds the test merge that a
  /// pull request's run checks out.
  Future<void> mergeBranch(
    String name,
    List<Map<String, String?>> changes,
  ) async {
    final target = await git(['rev-parse', '--abbrev-ref', 'HEAD']);
    await git(['checkout', '-q', '-b', name]);
    for (final files in changes) {
      await commit(files);
    }
    await git(['checkout', '-q', target]);
    await git(['merge', '-q', '--no-ff', '--no-edit', name]);
  }

  /// A depth-1 clone of this repository beside it.
  Future<_Repo> shallowClone() async {
    final clone = _Repo._(_root, Directory('${_root.path}/shallow'));
    await git([
      'clone',
      '-q',
      '--depth',
      '1',
      'file://${directory.path}',
      clone.directory.path,
    ]);
    return clone;
  }

  /// Runs [script] with the flags the Actions runner gives a `shell: bash`
  /// step.
  Future<_GuardResult> guard(String script) async {
    final output = File('${directory.path}.output');
    await output.writeAsString('');
    final result = await Process.run(
      'bash',
      ['--noprofile', '--norc', '-eo', 'pipefail', '-c', script],
      workingDirectory: directory.path,
      includeParentEnvironment: false,
      environment: {..._environment, 'GITHUB_OUTPUT': output.path},
    );
    return (
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      outputs: {
        for (final line in await output.readAsLines())
          if (line.split('=') case [final key, final value]) key: value,
      },
    );
  }

  /// Runs git in this repository and returns its trimmed output.
  Future<String> git(List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      workingDirectory: directory.existsSync() ? directory.path : _root.path,
      includeParentEnvironment: false,
      environment: {
        ..._environment,
        for (final role in ['AUTHOR', 'COMMITTER']) ...{
          'GIT_${role}_NAME': 'test',
          'GIT_${role}_EMAIL': 'test@example.invalid',
        },
      },
    );
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
    }
    return '${result.stdout}'.trim();
  }
}
