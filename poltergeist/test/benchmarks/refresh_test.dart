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
          'scenarioConfig': _p3Config,
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

  RefreshPool pool(Map<int, String> artifacts, {TierBBaseline? baseline}) =>
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

    test('excludes unreadable, checker-rejected and tier-A-only runs', () {
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
      });

      expect(result.usedRuns, isEmpty);
      expect(result.excludedRuns[1], startsWith('unreadable JSON'));
      expect(result.excludedRuns[2], contains('duplicate observation'));
      expect(result.excludedRuns[3], 'no tier-B rows');
    });

    test('gives a scenario without ok rows no entry', () {
      final result = pool({1: _artifact(), 2: _artifact(), 3: _artifact()});

      expect(result.entries.keys, ['P1']);
      expect(result.scenariosWithoutEntry, {'P6': 3});
      expect(result.warnings, isEmpty);
    });

    test('warns when a landed scenario has no ok rows', () {
      final result = pool({1: _artifact(p1Values: [])});

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
    late List<String> files;
    final out = MemorySink();
    final err = MemorySink();

    setUp(() {
      exitCode = 0;
      temp = Directory.systemTemp.createTempSync('d12-refresh-test');
      artifacts = '${temp.path}/artifacts';
      final budgets = File('${temp.path}/budgets.json')
        ..writeAsStringSync(jsonEncode(_catalogJson));
      final baseline = File('${temp.path}/baseline.json')
        ..writeAsStringSync(jsonEncode(_baselineJson()));
      files = ['--budgets', budgets.path, '--baseline', baseline.path];
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

    test('sample dispatches until enough runs qualify', () async {
      final actions = _FakeActions(
        artifactsByRun: {
          1: _artifact(),
          2: _artifact(cpu: _otherCpu),
          3: _artifact(),
        },
      );

      await run([
        'sample',
        '--branch',
        'bench/side',
        '--artifacts',
        artifacts,
        '--set',
        'runnerImage=$_newImage',
        '--runs',
        '2',
        ...files,
      ], actions);

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

    test('sample stops when its dispatch budget is spent', () async {
      final actions = _FakeActions(
        artifactsByRun: {
          1: _artifact(image: _oldImage),
          2: _artifact(),
        },
      );

      await run([
        'sample',
        '--branch',
        'bench/side',
        '--artifacts',
        artifacts,
        '--set',
        'runnerImage=$_newImage',
        '--max-dispatches',
        '2',
        ...files,
      ], actions);

      expect(actions.dispatched, hasLength(2));
      expect(out.text, contains('dispatch budget spent with 1 of 3'));
    });

    test('sample dispatches nothing once enough runs qualify', () async {
      for (final runId in [7, 8, 9]) {
        Directory('$artifacts/$runId').createSync(recursive: true);
        File(
          '$artifacts/$runId/$benchResultsFileName',
        ).writeAsStringSync(_artifact());
      }
      final actions = _FakeActions();

      await run([
        'sample',
        '--branch',
        'bench/side',
        '--artifacts',
        artifacts,
        '--set',
        'runnerImage=$_newImage',
        ...files,
      ], actions);

      expect(actions.dispatched, isEmpty);
      expect(out.text, contains('3 of 3 runs qualify'));
    });

    test('sample refuses main', () async {
      final actions = _FakeActions();

      await run([
        'sample',
        '--branch',
        mainBranch,
        '--artifacts',
        artifacts,
      ], actions);

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

      await expectLater(
        run([
          'sample',
          '--branch',
          'bench/side',
          '--artifacts',
          artifacts,
          ...files,
        ], actions),
        throwsStateError,
      );
      expect(actions.cancelled, isEmpty);
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
          ],
        },
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

      expect(actions.downloads, [1, 2]);
      expect(File('$artifacts/2/$benchResultsFileName').existsSync(), isTrue);
    });

    test('pool --write refuses a pool below the minimum', () async {
      Directory('$artifacts/1').createSync(recursive: true);
      File('$artifacts/1/$benchResultsFileName').writeAsStringSync(_artifact());
      final before = File(files[3]).readAsStringSync();

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
      expect(File(files[3]).readAsStringSync(), before);
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
  });
}

/// In-memory GitHub: each dispatched run's D12 job is done at its first
/// poll, and a cancelled run then reads as completed.
class _FakeActions implements ActionsClient {
  final Map<int, String> artifactsByRun;
  final Map<String, List<CiRun>> runsByBranch;
  final CiRunState Function(int runId)? stateOf;

  final dispatched = <(String, int)>[];
  final cancelled = <int>[];
  final downloads = <int>[];
  final _branchOf = <int, String>{};

  _FakeActions({
    this.artifactsByRun = const {},
    this.runsByBranch = const {},
    this.stateOf,
  });

  @override
  Future<int> dispatchSample(String branch) async {
    final runId = dispatched.length + 1;
    dispatched.add((branch, runId));
    _branchOf[runId] = branch;
    return runId;
  }

  @override
  Future<CiRunState> runState(int runId) async =>
      stateOf?.call(runId) ??
      CiRunState(
        branch: _branchOf[runId]!,
        event: RunEvent.workflowDispatch,
        runCompleted: cancelled.contains(runId),
        benchCompleted: true,
      );

  @override
  Future<bool> downloadBenchResults(int runId, String directory) async {
    downloads.add(runId);
    final text = artifactsByRun[runId];
    if (text == null) {
      return false;
    }

    Directory(directory).createSync(recursive: true);
    File('$directory/$benchResultsFileName').writeAsStringSync(text);
    return true;
  }

  @override
  Future<void> cancel(int runId) async => cancelled.add(runId);

  @override
  Future<List<CiRun>> listRuns(String branch) async =>
      runsByBranch[branch] ?? const [];
}
