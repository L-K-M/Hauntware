// GitHub Actions access for the D12 baseline refresh tool.
//
// refresh.dart talks only to [ActionsClient]; [GhActionsClient] owns the
// `gh` invocations, so tests substitute a fake and never reach GitHub.
library;

import 'dart:convert';
import 'dart:io';

const defaultRepository = 'L-K-M/Hauntware';
const ciWorkflow = 'ci.yml';
const mainBranch = 'main';
const benchJobName = 'D12 benchmarks';
const benchArtifactName = 'bench-results';
const benchResultsFileName = 'bench-results.json';

/// Most recent runs listed per branch; covers weeks of main history.
const _runListLimit = 300;

/// gh's run status once a run can no longer change.
const _completedStatus = 'completed';

/// Run events whose bench job records tier B (ci.yml runs tier B only on
/// main pushes and manual dispatch, never on pull requests).
enum RunEvent {
  push('push'),
  workflowDispatch('workflow_dispatch'),
  other('');

  final String ghName;

  const RunEvent(this.ghName);

  static RunEvent parse(String name) =>
      values.firstWhere((event) => event.ghName == name, orElse: () => other);

  bool get recordsTierB => this != other;
}

/// One ci.yml run as listed for a branch.
class CiRun {
  final int id;
  final RunEvent event;
  final DateTime createdAt;

  const CiRun({required this.id, required this.event, required this.createdAt});
}

/// Where a run stands, as far as the refresh cares.
class CiRunState {
  final String branch;
  final RunEvent event;
  final bool runCompleted;

  /// Whether the D12 job finished, which includes uploading its
  /// `bench-results` artifact (that step runs `if: always()`).
  final bool benchCompleted;

  const CiRunState({
    required this.branch,
    required this.event,
    required this.runCompleted,
    required this.benchCompleted,
  });
}

abstract interface class ActionsClient {
  /// ci.yml runs on [branch], newest first.
  Future<List<CiRun>> listRuns(String branch);

  Future<CiRunState> runState(int runId);

  /// Downloads [runId]'s `bench-results` artifact into [directory].
  /// False when the run has no such artifact (yet).
  Future<bool> downloadBenchResults(int runId, String directory);

  /// Dispatches ci.yml on [branch] with the M0 measurements skipped and
  /// returns the new run's id.
  Future<int> dispatchSample(String branch);

  Future<void> cancel(int runId);
}

/// [ActionsClient] over the authenticated `gh` CLI.
class GhActionsClient implements ActionsClient {
  final String repository;

  const GhActionsClient({this.repository = defaultRepository});

  @override
  Future<List<CiRun>> listRuns(String branch) async {
    final json = await _gh([
      'run',
      'list',
      '--workflow',
      ciWorkflow,
      '--branch',
      branch,
      '--limit',
      '$_runListLimit',
      '--json',
      'databaseId,event,createdAt',
    ]);
    return [
      for (final run in jsonDecode(json) as List<Object?>)
        if (run case {
          'databaseId': final int id,
          'event': final String event,
          'createdAt': final String createdAt,
        })
          CiRun(
            id: id,
            event: RunEvent.parse(event),
            createdAt: DateTime.parse(createdAt),
          ),
    ];
  }

  @override
  Future<CiRunState> runState(int runId) async {
    final json = await _gh([
      'run',
      'view',
      '$runId',
      '--json',
      'headBranch,event,status,jobs',
    ]);
    final run = jsonDecode(json) as Map<String, Object?>;
    final jobs = (run['jobs'] as List<Object?>).cast<Map<String, Object?>>();
    final bench = jobs.where((job) => job['name'] == benchJobName).firstOrNull;
    return CiRunState(
      branch: run['headBranch'] as String,
      event: RunEvent.parse(run['event'] as String),
      runCompleted: run['status'] == _completedStatus,
      benchCompleted: bench?['status'] == _completedStatus,
    );
  }

  @override
  Future<bool> downloadBenchResults(int runId, String directory) async {
    final result = await _run([
      'run',
      'download',
      '$runId',
      '--name',
      benchArtifactName,
      '--dir',
      directory,
    ]);
    return result.exitCode == 0;
  }

  @override
  Future<int> dispatchSample(String branch) async {
    final arguments = [
      'workflow',
      'run',
      ciWorkflow,
      '--ref',
      branch,
      '-f',
      'skip_m0=true',
    ];
    final result = await _run(arguments);
    _requireSuccess(arguments, result);

    // gh reports the created run's URL, e.g. .../actions/runs/40193700726,
    // on stdout or stderr depending on its version.
    final output = '${result.stdout}${result.stderr}';
    final match = RegExp(r'/actions/runs/(\d+)').firstMatch(output);
    if (match == null) {
      throw StateError(
        'gh did not report the dispatched run on $branch; update gh '
        '(output: ${output.trim()})',
      );
    }
    return int.parse(match.group(1)!);
  }

  @override
  Future<void> cancel(int runId) => _gh(['run', 'cancel', '$runId']);

  /// stdout of a successful gh call; stderr may carry notices.
  Future<String> _gh(List<String> arguments) async {
    final result = await _run(arguments);
    _requireSuccess(arguments, result);
    return '${result.stdout}';
  }

  void _requireSuccess(List<String> arguments, ProcessResult result) {
    if (result.exitCode == 0) {
      return;
    }
    throw ProcessException(
      'gh',
      arguments,
      '${result.stderr}'.trim(),
      result.exitCode,
    );
  }

  Future<ProcessResult> _run(List<String> arguments) =>
      Process.run('gh', [...arguments, '--repo', repository]);
}
