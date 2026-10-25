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

/// Consecutive gh failures on one run that `sample` rides out before
/// giving up; a single transient failure must not abandon the runs it
/// dispatched.
const _maxConsecutiveGhFailures = 10;

/// `sample` dispatches only on branches under this prefix. A plain name
/// check would let `refs/heads/main` or another spelling of main through,
/// and a dispatch on main supersedes its queued push run.
const sideBranchPrefix = 'bench/';

/// Options each command reads; any other option is a usage error, so a
/// misplaced flag never silently changes nothing.
const _commandOptions = {
  RefreshCommand.collect: {'--artifacts', '--branch', '--since', '--repo'},
  RefreshCommand.sample: {
    '--artifacts',
    '--branch',
    '--set',
    '--runs',
    '--max-dispatches',
    '--budgets',
    '--baseline',
    '--repo',
  },
  RefreshCommand.pool: {
    '--artifacts',
    '--set',
    '--write',
    '--budgets',
    '--baseline',
  },
};

/// Options that may repeat; any other given twice is a usage error
/// rather than last-wins, e.g. two `--artifacts` directories.
const _repeatableOptions = {'--branch', '--set'};

const _usageText =
    '''
Usage: dart run test/benchmarks/refresh.dart <command> [options]
Collects D12 bench-results artifacts and pools them into a refreshed
tier-B baseline (README "Baseline refresh procedure").

Commands:
  collect   download the artifacts of ci.yml push and dispatch runs
            created since --since on each --branch (default main)
  sample    dispatch ci.yml on each --branch (side branches under
            $sideBranchPrefix at main's tip), keep each run's artifact, cancel
            the rest of the run, and redispatch until --runs runs qualify
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
    final given = <String>{};

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
      if (argument.startsWith('--') &&
          !_commandOptions[command]!.contains(argument)) {
        throw RefreshUsageException(
          '$argument does not apply to ${command.name}',
        );
      }
      if (!_repeatableOptions.contains(argument) && !given.add(argument)) {
        throw RefreshUsageException('$argument may appear once');
      }

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
          if (overrides.containsKey(axis)) {
            throw RefreshUsageException('--set ${axis.name} may appear once');
          }
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
    if (command == RefreshCommand.collect && since == null) {
      throw const RefreshUsageException('collect requires --since');
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

      final unsafe = branches.where(
        (branch) => !branch.startsWith(sideBranchPrefix),
      );
      if (unsafe.isNotEmpty) {
        throw RefreshUsageException(
          'sample dispatches only on $sideBranchPrefix* side branches, '
          'never main (got ${unsafe.join(', ')}); push one at main\'s tip '
          'first',
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

/// CLI body, exposed for in-process tests: returns the exit code instead
/// of setting the process-global [exitCode], which test files running in
/// parallel isolates would race on, and talks to GitHub only through
/// [client].
Future<int> refreshMain(
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
    return usageExitCode;
  }

  final command = cli.command;
  if (command == null) {
    stdoutSink.writeln(_usageText);
    return 0;
  }

  final actions = client ?? GhActionsClient(repository: cli.repository);
  try {
    switch (command) {
      case RefreshCommand.collect:
        await _collect(cli, actions, stdoutSink);
        return 0;
      case RefreshCommand.sample:
        return await _sample(cli, actions, stdoutSink, pollInterval);
      case RefreshCommand.pool:
        return _pool(cli, stdoutSink, stderrSink);
    }
  } on CheckDataException catch (error) {
    stderrSink.writeln('error: $error');
    return dataExitCode;
  } on FileSystemException catch (error) {
    stderrSink.writeln('error: $error');
    return ioExitCode;
  } on ProcessException catch (error) {
    stderrSink.writeln('error: $error');
    return ioExitCode;
  } on ActionsException catch (error) {
    stderrSink.writeln('error: $error');
    return ioExitCode;
  }
}

Future<void> _collect(
  RefreshArguments cli,
  ActionsClient actions,
  IOSink out,
) async {
  for (final branch in cli.branches) {
    for (final run in await actions.listRuns(branch, cli.since!)) {
      if (!run.event.recordsTierB) {
        continue;
      }
      if (_hasArtifact(cli.artifacts, run.id)) {
        continue;
      }

      final downloaded = await actions.downloadBenchResults(
        run.id,
        _runDirectory(cli.artifacts, run.id),
      );
      if (!downloaded) {
        out.writeln(
          'run ${run.id} ($branch): no $benchArtifactName artifact '
          '(cancelled before the D12 job, or still running)',
        );
        continue;
      }

      out.writeln(
        _hasArtifact(cli.artifacts, run.id)
            ? 'run ${run.id} ($branch): downloaded'
            : 'run ${run.id} ($branch): artifact holds no '
                  '$benchResultsFileName (the D12 job stopped early)',
      );
    }
  }
}

/// 0 once enough runs qualify, else [gradedFailureExitCode].
Future<int> _sample(
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

  return _Sampler(cli, actions, out, pollInterval, repool).run();
}

/// One `sample` invocation: the side-branch runs it dispatched and still
/// tracks, one per branch at a time.
class _Sampler {
  final RefreshArguments _cli;
  final ActionsClient _actions;
  final IOSink _out;
  final Duration _pollInterval;
  final RefreshPool Function() _repool;

  final _active = <String, int>{};
  final _cancelling = <int>{};
  late int _qualifying = _repool().usedRuns.length;
  late int _dispatchesLeft = _cli.maxDispatches;

  /// Consecutive gh failures per run, so healthy polls of one branch
  /// never mask a run that keeps failing on another.
  final _ghFailures = <int, int>{};

  _Sampler(
    this._cli,
    this._actions,
    this._out,
    this._pollInterval,
    this._repool,
  );

  Future<int> run() async {
    try {
      await _sampleUntilTarget();
    } catch (_) {
      // Whatever stopped the loop, the runs it dispatched keep going and
      // hold runners until someone cancels them.
      if (_active.isNotEmpty) {
        _out.writeln(
          'stopped with runs still going: ${_active.values.join(' ')}; '
          'cancel them by hand',
        );
      }
      rethrow;
    }

    if (_qualifying < _cli.runs) {
      _out.writeln('dispatch budget spent with $_qualifying of ${_cli.runs}');
      return gradedFailureExitCode;
    }
    return 0;
  }

  Future<void> _sampleUntilTarget() async {
    _out.writeln('$_qualifying of ${_cli.runs} runs qualify');
    for (final branch in _cli.branches) {
      if (_targetReached || _dispatchesLeft == 0) {
        break;
      }
      await _dispatch(branch);
    }

    while (_active.isNotEmpty) {
      await Future<void>.delayed(_pollInterval);

      for (final MapEntry(key: branch, value: runId)
          in _active.entries.toList()) {
        if (!await _poll(branch, runId)) {
          continue;
        }

        _active.remove(branch);
        final pool = _repool();
        _qualifying = pool.usedRuns.length;
        final verdict = pool.usedRuns.contains(runId)
            ? 'qualifies'
            : 'excluded (${pool.excludedRuns[runId] ?? 'no artifact'})';
        _out.writeln(
          'run $runId $verdict; $_qualifying of ${_cli.runs} qualify',
        );
        if (_targetReached || _dispatchesLeft == 0) {
          continue;
        }
        await _dispatch(branch);
      }
    }
  }

  bool get _targetReached => _qualifying >= _cli.runs;

  Future<void> _dispatch(String branch) async {
    final int runId;
    try {
      runId = await _actions.dispatchSample(branch);
    } on ProcessException {
      // gh can fail after GitHub created the run (e.g. a dropped
      // response), so a run nobody tracks may exist. Retrying could leave
      // a second one.
      _out.writeln(
        'dispatch on $branch failed; look for a run to cancel with '
        '`gh run list --branch $branch --event workflow_dispatch`',
      );
      rethrow;
    }
    _dispatchesLeft--;
    _active[branch] = runId;
    _out.writeln(
      'dispatched run $runId on $branch (cancel it by hand if this '
      'tool is interrupted)',
    );
  }

  /// One poll of [runId]; true once the run has completed. gh failures
  /// are retried at the next poll, up to a bound.
  Future<bool> _poll(String branch, int runId) async {
    try {
      final finished = await _advanceRun(branch, runId);
      _ghFailures.remove(runId);
      return finished;
    } on ProcessException catch (error) {
      final failures = _ghFailures.update(
        runId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      if (failures > _maxConsecutiveGhFailures) {
        rethrow;
      }
      _out.writeln('run $runId: gh failed, retrying ($error)');
      return false;
    }
  }

  /// Keeps [runId]'s artifact once its D12 job finishes, then cancels the
  /// rest of the run to free the runners. True once the run has
  /// completed; until then a redispatch on its branch would only queue
  /// behind it in the branch's concurrency group.
  Future<bool> _advanceRun(String branch, int runId) async {
    final state = await _actions.runState(runId);
    if (!state.benchCompleted && !state.runCompleted) {
      return false;
    }

    if (!_hasArtifact(_cli.artifacts, runId)) {
      await _actions.downloadBenchResults(
        runId,
        _runDirectory(_cli.artifacts, runId),
      );
    }
    if (state.runCompleted) {
      return true;
    }

    if (!_cancelling.contains(runId)) {
      _requireOwnDispatch(runId, branch, state);
      await _actions.cancel(runId);
      _cancelling.add(runId);
    }
    return false;
  }

  /// Proves [runId] is this tool's side-branch dispatch before it is
  /// cancelled. Anything else is a bug that must never cancel a run.
  static void _requireOwnDispatch(int runId, String branch, CiRunState state) {
    if (state.branch == branch &&
        state.branch != mainBranch &&
        state.event == RunEvent.workflowDispatch) {
      return;
    }

    throw StateError(
      'refusing to cancel run $runId: it is a ${state.event.ghName} run '
      'on ${state.branch}, not a dispatch on $branch',
    );
  }
}

/// 0 unless `--write` refused a short pool ([gradedFailureExitCode]).
int _pool(RefreshArguments cli, IOSink out, IOSink err) {
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
    return 0;
  }
  if (pool.usedRuns.length < minimumRefreshRuns) {
    err.writeln('not written: fewer than $minimumRefreshRuns runs qualify');
    return gradedFailureExitCode;
  }

  // Both documents are computed before either is written, and each lands
  // by rename, so a read or encode failure leaves both files untouched
  // and no file is ever half-written.
  final baselineText = updateBaselineJson(
    File(cli.baseline).readAsStringSync(),
    target,
    pool,
  );
  final budgetsText = updateBudgetsJson(
    File(cli.budgets).readAsStringSync(),
    target,
  );
  _replaceFile(cli.baseline, baselineText);
  _replaceFile(cli.budgets, budgetsText);
  out.writeln(
    'Wrote ${cli.baseline} and ${cli.budgets}. Update the pins in '
    'check_test.dart, then run the checker against the used artifacts '
    '(README step 4).',
  );
  return 0;
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

void _replaceFile(String path, String text) {
  final temp = File('$path.refresh-tmp')..writeAsStringSync(text, flush: true);
  temp.renameSync(path);
}

/// Run id → `bench-results.json` text for every run directory present;
/// null when the run's artifact holds no readable results file, so the
/// pool lists that run as excluded instead of dropping it unseen.
Map<int, String?> _readArtifacts(String directory) {
  final root = Directory(directory);
  if (!root.existsSync()) {
    return {};
  }

  return {
    for (final entry in root.listSync().whereType<Directory>())
      if (int.tryParse(p.basename(entry.path)) case final runId?)
        runId: _readResults(entry.path),
  };
}

String? _readResults(String runDirectory) {
  try {
    return File(p.join(runDirectory, benchResultsFileName)).readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

bool _hasArtifact(String directory, int runId) => File(
  p.join(_runDirectory(directory, runId), benchResultsFileName),
).existsSync();

String _runDirectory(String directory, int runId) =>
    p.join(directory, '$runId');

Future<void> main(List<String> arguments) async {
  exitCode = await refreshMain(arguments);
}
