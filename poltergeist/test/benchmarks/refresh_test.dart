// Tests for the D12 baseline refresh tool: the pure pooling core and the
// CLI's collect/sample/pool commands against a fake GitHub Actions client.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'check_cli_test.dart' show MemorySink;
import 'check_core.dart';
import 'refresh.dart';
import 'refresh_actions.dart';
import 'refresh_core.dart';

const _oldImage = 'ubuntu-latest@1.0';
const _newImage = 'ubuntu-latest@2.0';
const _recordedCpu = 'AMD EPYC 7763 64-Core Processor';
const _otherCpu = 'AMD EPYC 9V74 80-Core Processor';
const _tierBDart = 'dart-flutter-bundled';
const _tierADart = 'dart-sdk';
const _p1Config = 'local-entries-10000-first-paint';
const _p3Config = 'p3/v1';

final _catalogJson = {
  'schema': budgetsSchemaV2Id,
  'calibratedFingerprint': {
    'runnerImage': _oldImage,
    'arch': 'linux_x64',
    'dartVersion': _tierADart,
    'flutterVersion': null,
    'mode': 'aot',
    'cpuModel': _recordedCpu,
    'scenarioConfig': null,
  },
  'scenarios': [
    _budget('P1', 'b', 'ms', landed: true),
    _budget('P6', 'b', '%', landed: false),
    _budget('P3', 'a', 'ms', landed: true, config: _p3Config),
  ],
};

Map<String, Object?> _budget(
  String id,
  String tier,
  String unit, {
  required bool landed,
  String? config,
}) => {
  'id': id,
  'tier': tier,
  'summary': '$id scenario',
  'operator': 'lessThan',
  'value': 100,
  'unit': unit,
  'minimumRepetitions': 1,
  'landed': landed,
  'calibratedScenarioConfig': ?config,
};

Map<String, Object?> _baselineJson({String p1Config = _p1Config}) => {
  'schema': baselineSchemaV2Id,
  'fingerprint': _tierBFingerprint(_oldImage, _recordedCpu, null),
  'scenarios': {
    'P1': {
      'median': 10.0,
      'unit': 'ms',
      'repetitions': 3,
      'scenarioConfig': p1Config,
    },
  },
};

Map<String, Object?> _tierBFingerprint(
  String image,
  String cpu,
  String? config,
) => {
  'runnerImage': image,
  'arch': 'linux_x64',
  'dartVersion': _tierBDart,
  'flutterVersion': '3.47.2',
  'mode': 'profile',
  'cpuModel': cpu,
  'scenarioConfig': config,
};

/// A bench-results.json text: P1 rows with [p1Values], errored P6 rows,
/// and P3 rows with [p3Values] (tier A, on the same machine).
String _artifact({
  String image = _newImage,
  String cpu = _recordedCpu,
  List<double> p1Values = const [10, 11, 12],
  List<double> p3Values = const [5],
  String p1Config = _p1Config,
  String p3Config = _p3Config,
  String tierADart = _tierADart,
}) {
  final rows = [
    for (final (index, value) in p1Values.indexed)
      {
        'scenario': 'P1',
        'repetition': index,
        'status': 'ok',
        'value': value,
        'unit': 'ms',
        'fingerprint': _tierBFingerprint(image, cpu, p1Config),
      },
    {
      'scenario': 'P6',
      'repetition': 0,
      'status': 'error',
      'error': 'insufficient frame capture',
      'fingerprint': _tierBFingerprint(image, cpu, 'scroll'),
    },
    for (final (index, value) in p3Values.indexed)
      {
        'scenario': 'P3',
        'repetition': index,
        'status': 'ok',
        'value': value,
        'unit': 'ms',
        'fingerprint': {
          'runnerImage': image,
          'arch': 'linux_x64',
          'dartVersion': tierADart,
          'flutterVersion': null,
          'mode': 'aot',
          'cpuModel': cpu,
          'scenarioConfig': p3Config,
        },
      },
  ];
  return jsonEncode({'schema': resultsSchemaId, 'rows': rows});
}

void main() {
  final catalog = BudgetCatalog.fromJson(_catalogJson);
  final current = TierBBaseline.fromJson(_baselineJson(), catalog);
  final target = overrideAxes(current.fingerprint, {
    FingerprintAxis.runnerImage: _newImage,
  });

  RefreshPool pool(Map<int, String?> artifacts, {TierBBaseline? baseline}) =>
      poolRefresh(
        catalog: catalog,
        current: baseline ?? current,
        target: target,
        artifacts: artifacts,
      );

  group('poolRefresh', () {
    test('pools only runs matching the target on every axis', () {
      final result = pool({
        3: _artifact(p1Values: [13, 14, 15]),
        1: _artifact(p1Values: [10, 11, 12.0004]),
        2: _artifact(image: _oldImage),
        4: _artifact(cpu: _otherCpu, p1Values: [99]),
      });

      expect(result.usedRuns, [1, 3]);
      expect(result.excludedRuns, {
        2: 'runnerImage $_oldImage',
        4: 'cpuModel $_otherCpu',
      });

      // Six pooled rows: the even count averages the central pair, and
      // the committed median keeps three decimals.
      final p1 = result.entries['P1']!;
      expect(p1.median, 12.5);
      expect(p1.repetitions, 6);
      expect(p1.unit, 'ms');
      expect(p1.scenarioConfig, _p1Config);
      expect(result.tierAMedians['P3'], (median: 5.0, unit: 'ms', count: 2));
    });

    test('rounds medians to three decimals', () {
      final result = pool({
        1: _artifact(p1Values: [1.00049]),
        2: _artifact(p1Values: [1.00051]),
        3: _artifact(p1Values: [2]),
      });

      expect(result.entries['P1']!.median, 1.001);
    });

    test('excludes unreadable, checker-rejected and unmeasured runs', () {
      final duplicate = jsonDecode(_artifact()) as Map<String, Object?>;
      final rows = duplicate['rows'] as List<Object?>;
      rows.add(rows.first);
      final tierAOnly = jsonDecode(_artifact()) as Map<String, Object?>;
      (tierAOnly['rows'] as List<Object?>).removeWhere(
        (row) => (row as Map)['scenario'] != 'P3',
      );

      final result = pool({
        1: '{not json',
        2: jsonEncode(duplicate),
        3: jsonEncode(tierAOnly),
        4: null,
        5: _artifact(p1Values: []),
      });

      expect(result.usedRuns, isEmpty);
      expect(result.excludedRuns[1], startsWith('unreadable JSON'));
      expect(result.excludedRuns[2], contains('duplicate observation'));
      expect(result.excludedRuns[3], 'no tier-B rows');
      expect(result.excludedRuns[4], 'no readable $benchResultsFileName');
      // Only errored tier-B rows: the run measured nothing to pool.
      expect(result.excludedRuns[5], 'no ok tier-B rows');
    });

    test('gives a scenario without ok rows no entry', () {
      final result = pool({1: _artifact(), 2: _artifact(), 3: _artifact()});

      expect(result.entries.keys, ['P1']);
      expect(result.scenariosWithoutEntry, {'P6': 3});
      expect(result.warnings, isEmpty);
    });

    test('warns when a landed scenario has no ok rows', () {
      final p1Missing = jsonDecode(_artifact()) as Map<String, Object?>;
      final rows = p1Missing['rows'] as List<Object?>;
      rows.removeWhere((row) => (row as Map)['scenario'] == 'P1');
      rows.add({
        'scenario': 'P6',
        'repetition': 1,
        'status': 'ok',
        'value': 0.1,
        'unit': '%',
        'fingerprint': _tierBFingerprint(_newImage, _recordedCpu, 'scroll'),
      });

      final result = pool({1: jsonEncode(p1Missing)});

      expect(
        result.warnings,
        contains(startsWith('P1 is landed but has no ok rows')),
      );
    });

    test('warns about a short pool, a moved config and tier-A drift', () {
      final result = pool(
        {1: _artifact(tierADart: 'dart-sdk-next')},
        baseline: TierBBaseline.fromJson(
          _baselineJson(p1Config: 'older-config'),
          catalog,
        ),
      );

      expect(result.warnings, hasLength(3));
      expect(result.warnings, contains(startsWith('only 1 run(s) match')));
      expect(
        result.warnings,
        contains('P1 scenarioConfig moved from older-config to $_p1Config'),
      );
      expect(
        result.warnings,
        contains(startsWith('tier-A rows ran with dartVersion dart-sdk-next')),
      );
    });

    test('warns when a tier-A scenario ran under another config', () {
      final result = pool({
        1: _artifact(p3Config: 'p3/v2'),
        2: _artifact(),
        3: _artifact(),
      });

      expect(result.usedRuns, [1, 2, 3]);
      expect(result.warnings, [
        'P3 ran under p3/v2, but budgets.json calibrates $_p3Config: '
            'recalibrate tier A separately',
      ]);
    });

    test('refuses to pool runs that disagree on a config', () {
      expect(
        () => pool({1: _artifact(), 2: _artifact(p1Config: 'other')}),
        throwsA(
          isA<CheckDataException>().having(
            (error) => error.message,
            'message',
            contains('disagree on P1 scenarioConfig'),
          ),
        ),
      );
    });
  });

  group('committed-file updates', () {
    final result = pool({
      1: _artifact(p1Values: [20]),
      2: _artifact(p1Values: [21]),
      3: _artifact(p1Values: [22]),
    });

    test('moves the baseline fingerprint and replaces its entries', () {
      final text = updateBaselineJson(
        const JsonEncoder.withIndent('  ').convert(_baselineJson()),
        target,
        result,
      );

      expect(text, endsWith('}\n'));
      expect(text, contains('\n  "fingerprint": {\n    "runnerImage"'));
      final updated = TierBBaseline.fromJson(jsonDecode(text), catalog);
      expect(updated.fingerprint.runnerImage, _newImage);
      expect(updated.fingerprint.cpuModel, _recordedCpu);
      expect(updated.scenarios.keys, ['P1']);
      expect(updated.scenarios['P1']!.median, 21);
      expect(updated.scenarios['P1']!.repetitions, 3);
      expect(updated.scenarios['P1']!.scenarioConfig, _p1Config);
    });

    test('moves only the machine axes of the tier-A calibration', () {
      final text = updateBudgetsJson(jsonEncode(_catalogJson), target);

      final calibration = BudgetCatalog.fromJson(
        jsonDecode(text),
      ).calibratedFingerprint!;
      expect(calibration.runnerImage, _newImage);
      expect(calibration.dartVersion, _tierADart);
      expect(calibration.mode, 'aot');
      expect(calibration.flutterVersion, isNull);
    });

    test('leaves a missing calibration missing', () {
      final uncalibrated = jsonEncode({
        ..._catalogJson,
        'calibratedFingerprint': null,
      });

      expect(updateBudgetsJson(uncalibrated, target), uncalibrated);
    });
  });

  group('refresh CLI', () {
    late Directory temp;
    late String artifacts;
    late String budgetsPath;
    late String baselinePath;
    late List<String> files;
    final out = MemorySink();
    final err = MemorySink();

    setUp(() {
      exitCode = 0;
      temp = Directory.systemTemp.createTempSync('d12-refresh-test');
      artifacts = '${temp.path}/artifacts';
      budgetsPath = '${temp.path}/budgets.json';
      baselinePath = '${temp.path}/baseline.json';
      File(budgetsPath).writeAsStringSync(jsonEncode(_catalogJson));
      File(baselinePath).writeAsStringSync(jsonEncode(_baselineJson()));
      files = ['--budgets', budgetsPath, '--baseline', baselinePath];
      out.clear();
      err.clear();
    });

    tearDown(() {
      exitCode = 0;
      temp.deleteSync(recursive: true);
    });

    Future<void> run(List<String> arguments, _FakeActions actions) =>
        refreshMain(
          arguments,
          out: out,
          err: err,
          client: actions,
          pollInterval: Duration.zero,
        );

    void storeArtifact(int runId, String text) {
      Directory('$artifacts/$runId').createSync(recursive: true);
      File('$artifacts/$runId/$benchResultsFileName').writeAsStringSync(text);
    }

    List<String> sample(
      List<String> branches, [
      List<String> extra = const [],
    ]) => [
      'sample',
      for (final branch in branches) ...['--branch', branch],
      '--artifacts',
      artifacts,
      '--set',
      'runnerImage=$_newImage',
      ...extra,
      ...files,
    ];

    test('sample dispatches until enough runs qualify', () async {
      final actions = _FakeActions(
        artifactsByRun: {
          1: _artifact(),
          2: _artifact(cpu: _otherCpu),
          3: _artifact(),
        },
      );

      await run(sample(['bench/side'], ['--runs', '2']), actions);

      expect(exitCode, 0);
      expect(actions.dispatched, [
        ('bench/side', 1),
        ('bench/side', 2),
        ('bench/side', 3),
      ]);
      expect(actions.cancelled, [1, 2, 3]);
      expect(out.text, contains('run 2 excluded (cpuModel $_otherCpu)'));
      expect(out.text, contains('run 3 qualifies; 2 of 2 qualify'));
    });

    test('sample waits for the D12 job and for each cancellation', () async {
      // The fake fails the test if a run is cancelled before its D12 job
      // finished, or a branch is redispatched while its run still goes.
      final actions = _FakeActions(
        artifactsByRun: {1: _artifact(), 2: _artifact()},
        benchPolls: 3,
        settlePolls: 2,
      );

      await run(sample(['bench/side'], ['--runs', '2']), actions);

      expect(exitCode, 0);
      expect(actions.cancelled, [1, 2]);
      expect(actions.dispatched, hasLength(2));
    });

    test('sample keeps one run per branch going in parallel', () async {
      final actions = _FakeActions(
        artifactsByRun: {
          for (final id in [1, 2, 3, 4]) id: _artifact(),
        },
      );

      await run(sample(['bench/a', 'bench/b']), actions);

      expect(actions.dispatched, [
        ('bench/a', 1),
        ('bench/b', 2),
        ('bench/a', 3),
        ('bench/b', 4),
      ]);
      expect(actions.cancelled, [1, 2, 3, 4]);
      expect(exitCode, 0);
    });

    test('sample stops when its dispatch budget is spent', () async {
      final actions = _FakeActions(
        artifactsByRun: {
          1: _artifact(image: _oldImage),
          2: _artifact(),
        },
      );

      await run(sample(['bench/side'], ['--max-dispatches', '2']), actions);

      expect(exitCode, 1);
      expect(actions.dispatched, hasLength(2));
      expect(out.text, contains('dispatch budget spent with 1 of 3'));
    });

    test('sample rides out a transient gh failure', () async {
      final actions = _FakeActions(
        artifactsByRun: {1: _artifact()},
        failingStateCalls: 2,
      );

      await run(sample(['bench/side'], ['--runs', '1']), actions);

      expect(exitCode, 0);
      expect(actions.cancelled, [1]);
      expect(out.text, contains('run 1: gh failed, retrying'));
      expect(out.text, contains('run 1 qualifies; 1 of 1 qualify'));
    });

    test('sample dispatches nothing once enough runs qualify', () async {
      for (final runId in [7, 8, 9]) {
        storeArtifact(runId, _artifact());
      }
      final actions = _FakeActions();

      await run(sample(['bench/side']), actions);

      expect(actions.dispatched, isEmpty);
      expect(out.text, contains('3 of 3 runs qualify'));
    });

    for (final branch in [mainBranch, 'refs/heads/main', 'heads/main', 'x']) {
      test('sample refuses $branch', () async {
        final actions = _FakeActions();

        await run(sample([branch]), actions);

        expect(exitCode, 64);
        expect(err.text, contains('only on bench/* side branches'));
        expect(actions.dispatched, isEmpty);
      });
    }

    test('sample rejects a repeated branch', () async {
      final actions = _FakeActions();

      await run(sample(['bench/side', 'bench/side']), actions);

      expect(exitCode, 64);
      expect(actions.dispatched, isEmpty);
    });

    test('sample never cancels a run it did not dispatch', () async {
      final actions = _FakeActions(
        artifactsByRun: {1: _artifact()},
        stateOf: (runId) => const CiRunState(
          branch: mainBranch,
          event: RunEvent.push,
          runCompleted: false,
          benchCompleted: true,
        ),
      );

      await expectLater(run(sample(['bench/side']), actions), throwsStateError);
      expect(actions.cancelled, isEmpty);
      expect(out.text, contains('stopped with runs still going: 1'));
    });

    test('collect downloads new push and dispatch runs once', () async {
      final since = DateTime.utc(2026, 10, 23);
      final actions = _FakeActions(
        artifactsByRun: {1: _artifact(), 2: _artifact(), 4: _artifact()},
        runsByBranch: {
          mainBranch: [
            CiRun(id: 1, event: RunEvent.push, createdAt: since),
            CiRun(id: 2, event: RunEvent.workflowDispatch, createdAt: since),
            CiRun(id: 3, event: RunEvent.other, createdAt: since),
            CiRun(
              id: 4,
              event: RunEvent.push,
              createdAt: since.subtract(const Duration(seconds: 1)),
            ),
            CiRun(id: 5, event: RunEvent.push, createdAt: since),
            CiRun(id: 6, event: RunEvent.push, createdAt: since),
          ],
        },
        resultlessArtifacts: {5},
      );
      final arguments = [
        'collect',
        '--since',
        since.toIso8601String(),
        '--artifacts',
        artifacts,
      ];

      await run(arguments, actions);
      await run(arguments, actions);

      // Runs 5 and 6 never yield a results file, so each attempt retries.
      expect(actions.downloads, [1, 2, 5, 6, 5, 6]);
      expect(out.text, contains('run 5 (main): artifact holds no'));
      expect(out.text, contains('run 6 (main): no bench-results artifact'));
      expect(File('$artifacts/2/$benchResultsFileName').existsSync(), isTrue);
    });

    test('pool --write updates both committed files', () async {
      for (final runId in [1, 2, 3]) {
        storeArtifact(runId, _artifact(p1Values: [runId + 20]));
      }
      Directory('$artifacts/4').createSync(recursive: true);

      await run([
        'pool',
        '--artifacts',
        artifacts,
        '--set',
        'runnerImage=$_newImage',
        '--write',
        ...files,
      ], _FakeActions());

      expect(exitCode, 0);
      expect(out.text, contains('4: no readable $benchResultsFileName'));
      final baseline = TierBBaseline.fromJson(
        jsonDecode(File(baselinePath).readAsStringSync()),
        catalog,
      );
      expect(baseline.fingerprint.runnerImage, _newImage);
      expect(baseline.scenarios['P1']!.median, 22);
      final budgets = BudgetCatalog.fromJson(
        jsonDecode(File(budgetsPath).readAsStringSync()),
      );
      expect(budgets.calibratedFingerprint!.runnerImage, _newImage);
      expect(
        temp.listSync().map((entry) => entry.path),
        isNot(contains(endsWith('-tmp'))),
      );
    });

    test('pool --write refuses a pool below the minimum', () async {
      storeArtifact(1, _artifact());
      final before = File(baselinePath).readAsStringSync();

      await run([
        'pool',
        '--artifacts',
        artifacts,
        '--set',
        'runnerImage=$_newImage',
        '--write',
        ...files,
      ], _FakeActions());

      expect(exitCode, 1);
      expect(err.text, contains('not written'));
      expect(File(baselinePath).readAsStringSync(), before);
    });

    test('rejects an unknown --set axis', () async {
      await run([
        'pool',
        '--artifacts',
        artifacts,
        '--set',
        'scenarioConfig=x',
      ], _FakeActions());

      expect(exitCode, 64);
      expect(err.text, contains('--set expects <axis>=<value>'));
    });

    test('rejects options the command does not read', () async {
      await run([
        'pool',
        '--artifacts',
        artifacts,
        '--branch',
        'bench/side',
      ], _FakeActions());

      expect(exitCode, 64);
      expect(err.text, contains('--branch does not apply to pool'));
    });
  });

  group('GhActionsClient', () {
    test('dispatches through the API and reads the created run id', () async {
      final gh = _FakeGh(['{"workflow_run_id": 42, "run_url": "u"}']);

      final runId = await gh.client.dispatchSample('bench/side');

      expect(runId, 42);
      expect(gh.calls.single, [
        'api',
        '--method',
        'POST',
        'repos/o/r/actions/workflows/ci.yml/dispatches',
        '-f',
        'ref=bench/side',
        '-f',
        'inputs[skip_m0]=true',
        '-F',
        'return_run_details=true',
      ]);
    });

    test('names the orphaned dispatch when GitHub returns no id', () async {
      final gh = _FakeGh(['']);

      expect(
        () => gh.client.dispatchSample('bench/side'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('gh run list --branch bench/side'),
          ),
        ),
      );
    });

    test('reads the run and its D12 job state', () async {
      final gh = _FakeGh([
        jsonEncode({
          'headBranch': 'bench/side',
          'event': 'workflow_dispatch',
          'status': 'in_progress',
          'jobs': [
            {'name': 'Planchette client (linux)', 'status': 'in_progress'},
            {'name': benchJobName, 'status': 'completed'},
          ],
        }),
      ]);

      final state = await gh.client.runState(7);

      expect(state.branch, 'bench/side');
      expect(state.event, RunEvent.workflowDispatch);
      expect(state.runCompleted, isFalse);
      expect(state.benchCompleted, isTrue);
      expect(gh.calls.single, [
        'run',
        'view',
        '7',
        '--json',
        'headBranch,event,status,jobs',
        '--repo',
        'o/r',
      ]);
    });

    test('reports a missing or expired artifact without downloading', () async {
      for (final listing in [
        {'artifacts': <Object?>[]},
        {
          'artifacts': [
            {'name': benchArtifactName, 'expired': true},
          ],
        },
      ]) {
        final gh = _FakeGh([jsonEncode(listing)]);

        expect(await gh.client.downloadBenchResults(7, 'dir'), isFalse);
        expect(gh.calls, hasLength(1));
      }
    });

    test('downloads an available artifact and surfaces failures', () async {
      final listing = jsonEncode({
        'artifacts': [
          {'name': benchArtifactName, 'expired': false},
        ],
      });

      final gh = _FakeGh([listing, '']);
      expect(await gh.client.downloadBenchResults(7, 'dir'), isTrue);
      expect(gh.calls.last, [
        'run',
        'download',
        '7',
        '--name',
        benchArtifactName,
        '--dir',
        'dir',
        '--repo',
        'o/r',
      ]);

      final failing = _FakeGh([listing], failAt: 1);
      await expectLater(
        failing.client.downloadBenchResults(7, 'dir'),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}

/// Scripted `gh`: answers each call with the next stdout, failing the
/// call at index [failAt] the way an expired token would.
class _FakeGh {
  final List<String> _stdout;
  final int? failAt;
  final calls = <List<String>>[];

  _FakeGh(this._stdout, {this.failAt});

  GhActionsClient get client =>
      GhActionsClient(repository: 'o/r', runner: _run);

  Future<ProcessResult> _run(String executable, List<String> arguments) async {
    final index = calls.length;
    calls.add(arguments);
    if (index == failAt) {
      return ProcessResult(0, 1, '', 'HTTP 401: Bad credentials');
    }
    return ProcessResult(0, 0, _stdout[index], '');
  }
}

/// In-memory GitHub. A dispatched run's D12 job finishes after
/// [benchPolls] polls, and a cancelled run completes [settlePolls] polls
/// after the cancel. It fails the test when the tool cancels a run before
/// its D12 job finished or redispatches a branch whose run still goes.
class _FakeActions implements ActionsClient {
  final Map<int, String> artifactsByRun;
  final Map<String, List<CiRun>> runsByBranch;
  final Set<int> resultlessArtifacts;
  final CiRunState Function(int runId)? stateOf;
  final int benchPolls;
  final int settlePolls;

  /// runState calls that fail like an unreachable GitHub before the
  /// fake starts answering.
  int failingStateCalls;

  final dispatched = <(String, int)>[];
  final cancelled = <int>[];
  final downloads = <int>[];
  final _branchOf = <int, String>{};
  final _polls = <int, int>{};
  final _cancelledAtPoll = <int, int>{};

  _FakeActions({
    this.artifactsByRun = const {},
    this.runsByBranch = const {},
    this.resultlessArtifacts = const {},
    this.stateOf,
    this.benchPolls = 0,
    this.settlePolls = 0,
    this.failingStateCalls = 0,
  });

  bool _benchDone(int runId) => (_polls[runId] ?? 0) > benchPolls;

  bool _runDone(int runId) =>
      _cancelledAtPoll.containsKey(runId) &&
      _polls[runId]! > _cancelledAtPoll[runId]! + settlePolls;

  @override
  Future<int> dispatchSample(String branch) async {
    final previous = dispatched.where((entry) => entry.$1 == branch).lastOrNull;
    if (previous != null && !_runDone(previous.$2)) {
      fail('redispatched $branch while run ${previous.$2} still goes');
    }

    final runId = dispatched.length + 1;
    dispatched.add((branch, runId));
    _branchOf[runId] = branch;
    return runId;
  }

  @override
  Future<CiRunState> runState(int runId) async {
    if (failingStateCalls > 0) {
      failingStateCalls--;
      throw const ProcessException('gh', ['run', 'view'], 'timeout', 1);
    }

    _polls.update(runId, (count) => count + 1, ifAbsent: () => 1);
    return stateOf?.call(runId) ??
        CiRunState(
          branch: _branchOf[runId]!,
          event: RunEvent.workflowDispatch,
          runCompleted: _runDone(runId),
          benchCompleted: _benchDone(runId),
        );
  }

  @override
  Future<bool> downloadBenchResults(int runId, String directory) async {
    downloads.add(runId);
    if (resultlessArtifacts.contains(runId)) {
      Directory(directory).createSync(recursive: true);
      return true;
    }

    final text = artifactsByRun[runId];
    if (text == null) {
      return false;
    }

    Directory(directory).createSync(recursive: true);
    File('$directory/$benchResultsFileName').writeAsStringSync(text);
    return true;
  }

  @override
  Future<void> cancel(int runId) async {
    if (stateOf == null && !_benchDone(runId)) {
      fail('cancelled run $runId before its D12 job finished');
    }
    cancelled.add(runId);
    _cancelledAtPoll[runId] = _polls[runId] ?? 0;
  }

  @override
  Future<List<CiRun>> listRuns(String branch) async =>
      runsByBranch[branch] ?? const [];
}
