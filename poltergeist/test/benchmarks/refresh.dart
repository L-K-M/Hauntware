// D12 baseline refresh CLI (README "Baseline refresh procedure").
//
// Gathers exact-fingerprint `bench-results` artifacts and pools them into
// the committed tier-B baseline: the measurement half of a refresh PR.
//
//   collect ─► <artifacts>/<run-id>/bench-results.json ◄─ sample
//                            │
//                            ▼
//                          pool ─► tier-b-baseline.json, budgets.json
//
// `collect` downloads main-branch artifacts. `sample` adds side-branch
// dispatches when main CI is held up: it dispatches ci.yml on side
// branches cut at main's tip, downloads each run's artifact once the D12
// job finishes, cancels the rest of that run to free the runners, and
// dispatches again until enough runs qualify. It never dispatches on
// main (that would supersede a queued main push run) and cancels only
// runs it dispatched itself.
//
// Exit codes: 0 success, 1 a pool too small to write, 64 usage, 65
// malformed inputs or disagreeing pooled configs, 74 IO or gh failures.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'check.dart'
    show
        dataExitCode,
        defaultBaselinePath,
        defaultBudgetsPath,
        gradedFailureExitCode,
        ioExitCode,
        usageExitCode;
import 'check_core.dart';
import 'refresh_actions.dart';
import 'refresh_core.dart';

/// Default bound on side-branch dispatches per `sample` invocation.
const defaultMaxDispatches = 6;

/// How often `sample` polls its runs.
const defaultPollInterval = Duration(minutes: 1);

/// Consecutive gh failures `sample` rides out before giving up; a single
/// transient failure must not abandon the runs it dispatched.
const _maxConsecutiveGhFailures = 10;

const _usageText =
    '''
Usage: dart run test/benchmarks/refresh.dart <command> [options]
Collects D12 bench-results artifacts and pools them into a refreshed
tier-B baseline (README "Baseline refresh procedure").

Commands:
  collect   download the artifacts of ci.yml push and dispatch runs
            created since --since on each --branch (default main)
  sample    dispatch ci.yml on each --branch (side branches at main's
            tip, never main), keep each run's artifact, cancel the rest
            of the run, and redispatch until --runs runs qualify
  pool      pool the qualifying artifacts and print the new baseline;
            --write updates the baseline and tier-A calibration files

Options:
  --artifacts <dir>       one <run-id>/bench-results.json per run (required)
  --set <axis>=<value>    target fingerprint override, e.g.
                          runnerImage=ubuntu-latest@20261023.334.3; the
                          other axes keep the committed baseline's values
  --branch <name>         collect/sample branch (repeatable)
  --since <ISO-8601>      collect: oldest run creation time
  --runs <n>              sample: qualifying runs to reach (default $minimumRefreshRuns)
  --max-dispatches <n>    sample: dispatch budget (default $defaultMaxDispatches)
  --write                 pool: write --baseline and --budgets
  --budgets <path>        budgets catalog (default $defaultBudgetsPath)
  --baseline <path>       tier-B baseline (default $defaultBaselinePath)
  --repo <owner/name>     GitHub repository (default $defaultRepository)
  -h, --help              print this usage''';

enum RefreshCommand { collect, sample, pool }

class RefreshUsageException implements Exception {
  final String message;

  const RefreshUsageException(this.message);

  @override
  String toString() => message;
}

class RefreshArguments {
  /// Null when help was requested.
  final RefreshCommand? command;
  final String artifacts;
  final List<String> branches;
  final DateTime? since;
  final Map<FingerprintAxis, String> overrides;
  final int runs;
  final int maxDispatches;
  final bool write;
  final String budgets;
  final String baseline;
  final String repository;

  const RefreshArguments({
    required this.command,
    required this.artifacts,
    required this.branches,
    required this.since,
    required this.overrides,
    required this.runs,
    required this.maxDispatches,
    required this.write,
    required this.budgets,
    required this.baseline,
    required this.repository,
  });

  static RefreshArguments parse(List<String> arguments) {
    if (arguments.isEmpty) {
      throw const RefreshUsageException('missing command');
    }
    if (arguments.any((argument) => argument == '-h' || argument == '--help')) {
      return _help;
    }

    final command = RefreshCommand.values
        .where((candidate) => candidate.name == arguments.first)
        .firstOrNull;
    if (command == null) {
      throw RefreshUsageException('unknown command ${arguments.first}');
    }

    String? artifacts;
    final branches = <String>[];
    DateTime? since;
    final overrides = <FingerprintAxis, String>{};
    var runs = minimumRefreshRuns;
    var maxDispatches = defaultMaxDispatches;
    var write = false;
    var budgets = defaultBudgetsPath;
    var baseline = defaultBaselinePath;
    var repository = defaultRepository;

    String takeValue(int index) {
      if (index + 1 >= arguments.length) {
        throw RefreshUsageException('${arguments[index]} requires a value');
      }
      return arguments[index + 1];
    }

    int takeCount(int index) {
      final value = int.tryParse(takeValue(index));
      if (value == null || value < 1) {
        throw RefreshUsageException(
          '${arguments[index]} must be a positive integer',
        );
      }
      return value;
    }

    for (var i = 1; i < arguments.length; i++) {
      final argument = arguments[i];
      switch (argument) {
        case '--artifacts':
          artifacts = takeValue(i++);
        case '--branch':
          branches.add(takeValue(i++));
        case '--since':
          since = DateTime.tryParse(takeValue(i++));
          if (since == null) {
            throw const RefreshUsageException(
              '--since must be an ISO-8601 time',
            );
          }
        case '--set':
          final (axis, value) = _parseOverride(takeValue(i++));
          overrides[axis] = value;
        case '--runs':
          runs = takeCount(i++);
        case '--max-dispatches':
          maxDispatches = takeCount(i++);
        case '--write':
          write = true;
        case '--budgets':
          budgets = takeValue(i++);
        case '--baseline':
          baseline = takeValue(i++);
        case '--repo':
          repository = takeValue(i++);
        default:
          throw RefreshUsageException('unknown option $argument');
      }
    }

    if (artifacts == null) {
      throw const RefreshUsageException('--artifacts is required');
    }
    if (write && command != RefreshCommand.pool) {
      throw const RefreshUsageException('--write applies to pool only');
    }
    if (command == RefreshCommand.collect && since == null) {
      throw const RefreshUsageException('collect requires --since');
    }
    if (command != RefreshCommand.collect && since != null) {
      throw const RefreshUsageException('--since applies to collect only');
    }
    if (branches.toSet().length != branches.length) {
      throw const RefreshUsageException('each --branch may appear once');
    }
    if (command == RefreshCommand.collect && branches.isEmpty) {
      branches.add(mainBranch);
    }
    if (command == RefreshCommand.sample) {
      if (branches.isEmpty) {
        throw const RefreshUsageException('sample requires --branch');
      }

      // A dispatch on main joins main's concurrency group and supersedes
      // its queued push run, which AGENTS.md forbids cancelling.
      if (branches.contains(mainBranch)) {
        throw const RefreshUsageException(
          'sample never dispatches on main; push a side branch at '
          "main's tip instead",
        );
      }
    }

    return RefreshArguments(
      command: command,
      artifacts: artifacts,
      branches: branches,
      since: since,
      overrides: overrides,
      runs: runs,
      maxDispatches: maxDispatches,
      write: write,
      budgets: budgets,
      baseline: baseline,
      repository: repository,
    );
  }

  static const _help = RefreshArguments(
    command: null,
    artifacts: '',
    branches: [],
    since: null,
    overrides: {},
    runs: minimumRefreshRuns,
    maxDispatches: defaultMaxDispatches,
    write: false,
    budgets: defaultBudgetsPath,
    baseline: defaultBaselinePath,
    repository: defaultRepository,
  );

  static (FingerprintAxis, String) _parseOverride(String text) {
    final separator = text.indexOf('=');
    final name = separator < 0 ? text : text.substring(0, separator);
    final axis = FingerprintAxis.values
        .where((candidate) => candidate.name == name)
        .firstOrNull;
    if (axis == null || separator < 0) {
      throw RefreshUsageException(
        '--set expects <axis>=<value> with axis one of '
        '${FingerprintAxis.values.map((axis) => axis.name).join(', ')} '
        '(got "$text")',
      );
    }
    return (axis, text.substring(separator + 1));
  }
}

/// CLI body, exposed for in-process tests: sets [exitCode] instead of
/// exiting, and talks to GitHub only through [client].
Future<void> refreshMain(
  List<String> arguments, {
  IOSink? out,
  IOSink? err,
  ActionsClient? client,
  Duration pollInterval = defaultPollInterval,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;

  final RefreshArguments cli;
  try {
    cli = RefreshArguments.parse(arguments);
  } on RefreshUsageException catch (error) {
    stderrSink.writeln('$error\n$_usageText');
    exitCode = usageExitCode;
    return;
  }

  final command = cli.command;
  if (command == null) {
    stdoutSink.writeln(_usageText);
    return;
  }

  final actions = client ?? GhActionsClient(repository: cli.repository);
  try {
    switch (command) {
      case RefreshCommand.collect:
        await _collect(cli, actions, stdoutSink);
      case RefreshCommand.sample:
        await _sample(cli, actions, stdoutSink, pollInterval);
      case RefreshCommand.pool:
        _pool(cli, stdoutSink, stderrSink);
    }
  } on CheckDataException catch (error) {
    stderrSink.writeln('error: $error');
    exitCode = dataExitCode;
  } on FileSystemException catch (error) {
    stderrSink.writeln('error: $error');
    exitCode = ioExitCode;
  } on ProcessException catch (error) {
    stderrSink.writeln('error: $error');
    exitCode = ioExitCode;
  }
}

Future<void> _collect(
  RefreshArguments cli,
  ActionsClient actions,
  IOSink out,
) async {
  for (final branch in cli.branches) {
    for (final run in await actions.listRuns(branch)) {
      if (run.createdAt.isBefore(cli.since!) || !run.event.recordsTierB) {
        continue;
      }
      if (_hasArtifact(cli.artifacts, run.id)) {
        continue;
      }

      final downloaded = await actions.downloadBenchResults(
        run.id,
        _runDirectory(cli.artifacts, run.id),
      );
      out.writeln(
        downloaded
            ? 'run ${run.id} ($branch): downloaded'
            : 'run ${run.id} ($branch): no $benchArtifactName artifact '
                  '(cancelled before the D12 job, or still running)',
      );
    }
  }
}

Future<void> _sample(
  RefreshArguments cli,
  ActionsClient actions,
  IOSink out,
  Duration pollInterval,
) async {
  final (catalog, current, target) = _loadTarget(cli);
  RefreshPool repool() => poolRefresh(
    catalog: catalog,
    current: current,
    target: target,
    artifacts: _readArtifacts(cli.artifacts),
  );

  var qualifying = repool().usedRuns.length;
  var dispatchesLeft = cli.maxDispatches;
  final active = <String, int>{};

  Future<void> dispatch(String branch) async {
    final runId = await actions.dispatchSample(branch);
    dispatchesLeft--;
    active[branch] = runId;
    out.writeln(
      'dispatched run $runId on $branch (cancel it by hand if this '
      'tool stops early)',
    );
  }

  out.writeln('$qualifying of ${cli.runs} runs qualify');
  for (final branch in cli.branches) {
    if (qualifying >= cli.runs || dispatchesLeft == 0) {
      break;
    }
    await dispatch(branch);
  }

  final cancelling = <int>{};
  var ghFailures = 0;
  while (active.isNotEmpty) {
    await Future<void>.delayed(pollInterval);

    for (final MapEntry(key: branch, value: runId) in active.entries.toList()) {
      final bool finished;
      try {
        finished = await _advanceRun(
          actions,
          cli.artifacts,
          branch,
          runId,
          cancelling,
        );
        ghFailures = 0;
      } on ProcessException catch (error) {
        ghFailures++;
        if (ghFailures > _maxConsecutiveGhFailures) {
          rethrow;
        }
        out.writeln('run $runId: gh failed, retrying ($error)');
        continue;
      }
      if (!finished) {
        continue;
      }

      active.remove(branch);
      final pool = repool();
      qualifying = pool.usedRuns.length;
      final verdict = pool.usedRuns.contains(runId)
          ? 'qualifies'
          : 'excluded (${pool.excludedRuns[runId] ?? 'no artifact'})';
      out.writeln('run $runId $verdict; $qualifying of ${cli.runs} qualify');
      if (qualifying >= cli.runs || dispatchesLeft == 0) {
        continue;
      }
      await dispatch(branch);
    }
  }

  if (qualifying < cli.runs) {
    out.writeln('dispatch budget spent with $qualifying of ${cli.runs}');
    exitCode = gradedFailureExitCode;
  }
}

/// Moves one dispatched run along: keeps its artifact once the D12 job
/// finishes, then cancels the rest of the run to free the runners. True
/// once the run has completed; until then a redispatch on its branch
/// would only queue behind it in the branch's concurrency group.
Future<bool> _advanceRun(
  ActionsClient actions,
  String artifacts,
  String branch,
  int runId,
  Set<int> cancelling,
) async {
  final state = await actions.runState(runId);
  if (!state.benchCompleted && !state.runCompleted) {
    return false;
  }

  if (!_hasArtifact(artifacts, runId)) {
    await actions.downloadBenchResults(runId, _runDirectory(artifacts, runId));
  }
  if (state.runCompleted) {
    return true;
  }

  if (!cancelling.contains(runId)) {
    await _cancelOwnRun(actions, runId, branch, state);
    cancelling.add(runId);
  }
  return false;
}

/// Cancels a run this tool dispatched, after proving it is one: a side
/// branch dispatch. Anything else is a bug that must not cancel a run.
Future<void> _cancelOwnRun(
  ActionsClient actions,
  int runId,
  String branch,
  CiRunState state,
) async {
  if (state.branch != branch ||
      state.event != RunEvent.workflowDispatch ||
      state.branch == mainBranch) {
    throw StateError(
      'refusing to cancel run $runId: it is a ${state.event.ghName} run '
      'on ${state.branch}, not a dispatch on $branch',
    );
  }
  await actions.cancel(runId);
}

void _pool(RefreshArguments cli, IOSink out, IOSink err) {
  final (catalog, current, target) = _loadTarget(cli);
  final pool = poolRefresh(
    catalog: catalog,
    current: current,
    target: target,
    artifacts: _readArtifacts(cli.artifacts),
  );

  out.writeln('Target fingerprint:');
  for (final axis in FingerprintAxis.values) {
    out.writeln('  ${axis.name}: ${axis.of(target)}');
  }
  out.writeln(
    'Used runs (${pool.usedRuns.length}): ${pool.usedRuns.join(' ')}',
  );
  out.writeln('Excluded runs:');
  for (final MapEntry(key: runId, value: reason) in pool.excludedRuns.entries) {
    out.writeln('  $runId: $reason');
  }
  out.writeln('Tier-B entries:');
  for (final MapEntry(key: id, value: entry) in pool.entries.entries) {
    out.writeln(
      '  $id: ${entry.median.toStringAsFixed(3)} ${entry.unit} '
      '(n=${entry.repetitions}, ${entry.scenarioConfig})',
    );
  }
  for (final MapEntry(key: id, value: errored)
      in pool.scenariosWithoutEntry.entries) {
    out.writeln('  $id: no ok rows ($errored errored), no entry');
  }
  out.writeln('Tier-A pooled medians:');
  for (final MapEntry(key: id, value: pooled) in pool.tierAMedians.entries) {
    out.writeln(
      '  $id: ${pooled.median.toStringAsFixed(3)} ${pooled.unit} '
      '(n=${pooled.count})',
    );
  }
  for (final warning in pool.warnings) {
    err.writeln('warning: $warning');
  }

  if (!cli.write) {
    return;
  }
  if (pool.usedRuns.length < minimumRefreshRuns) {
    err.writeln('not written: fewer than $minimumRefreshRuns runs qualify');
    exitCode = gradedFailureExitCode;
    return;
  }

  final baselineFile = File(cli.baseline);
  final budgetsFile = File(cli.budgets);
  baselineFile.writeAsStringSync(
    updateBaselineJson(baselineFile.readAsStringSync(), target, pool),
  );
  budgetsFile.writeAsStringSync(
    updateBudgetsJson(budgetsFile.readAsStringSync(), target),
  );
  out.writeln(
    'Wrote ${cli.baseline} and ${cli.budgets}. Update the pins in '
    'check_test.dart, then run the checker against the used artifacts '
    '(README step 4).',
  );
}

(BudgetCatalog, TierBBaseline, BenchFingerprint) _loadTarget(
  RefreshArguments cli,
) {
  final catalog = BudgetCatalog.fromJson(_decode(cli.budgets));
  final current = TierBBaseline.fromJson(_decode(cli.baseline), catalog);
  return (catalog, current, overrideAxes(current.fingerprint, cli.overrides));
}

Object? _decode(String path) {
  final text = File(path).readAsStringSync();
  try {
    return jsonDecode(text);
  } on FormatException catch (error) {
    throw CheckDataException('$path: ${error.message}');
  }
}

/// Run id → `bench-results.json` text for every run directory present.
Map<int, String> _readArtifacts(String directory) {
  final root = Directory(directory);
  if (!root.existsSync()) {
    return {};
  }

  return {
    for (final entry in root.listSync().whereType<Directory>())
      if (int.tryParse(p.basename(entry.path)) case final runId?)
        if (File(p.join(entry.path, benchResultsFileName)) case final file
            when file.existsSync())
          runId: file.readAsStringSync(),
  };
}

bool _hasArtifact(String directory, int runId) => File(
  p.join(_runDirectory(directory, runId), benchResultsFileName),
).existsSync();

String _runDirectory(String directory, int runId) =>
    p.join(directory, '$runId');

Future<void> main(List<String> arguments) => refreshMain(arguments);
