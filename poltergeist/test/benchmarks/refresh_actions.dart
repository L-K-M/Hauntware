// GitHub Actions access for the D12 baseline refresh tool.
//
// refresh.dart talks only to [ActionsClient]; [GhActionsClient] owns the
// `gh` invocations behind an injectable process runner, so tests
// substitute fakes and never reach GitHub.
library;

import 'dart:convert';
import 'dart:io';

const defaultRepository = 'L-K-M/Hauntware';
const ciWorkflow = 'ci.yml';
const mainBranch = 'main';
const benchJobName = 'D12 benchmarks';
const benchArtifactName = 'bench-results';

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
  /// False when the run has no such artifact; a failed download throws.
  Future<bool> downloadBenchResults(int runId, String directory);

  /// Dispatches ci.yml on [branch] with the M0 measurements skipped and
  /// returns the new run's id.
  Future<int> dispatchSample(String branch);

  Future<void> cancel(int runId);
}

/// Runs one `gh` invocation, e.g. [Process.run].
typedef GhRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// [ActionsClient] over the authenticated `gh` CLI.
class GhActionsClient implements ActionsClient {
  final String repository;
  final GhRunner _runner;

  const GhActionsClient({
    this.repository = defaultRepository,
    this._runner = Process.run,
  });

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
    // Ask for the artifact first, so "the run has none" never hides a
    // failed download (expired token, network, rate limit).
    final listing = await _api([
      'repos/$repository/actions/runs/$runId/artifacts?name=$benchArtifactName',
    ]);
    final artifacts =
        (jsonDecode(listing) as Map<String, Object?>)['artifacts'];
    final available = (artifacts as List<Object?>).any(
      (artifact) =>
          artifact is Map &&
          artifact['name'] == benchArtifactName &&
          artifact['expired'] != true,
    );
    if (!available) {
      return false;
    }

    await _gh([
      'run',
      'download',
      '$runId',
      '--name',
      benchArtifactName,
      '--dir',
      directory,
    ]);
    return true;
  }

  @override
  Future<int> dispatchSample(String branch) async {
    // The dispatch API names the run it created (gh's own `workflow run`
    // reads the same field), so the id never comes from parsing prose.
    final json = await _api([
      '--method',
      'POST',
      'repos/$repository/actions/workflows/$ciWorkflow/dispatches',
      '-f',
      'ref=$branch',
      '-f',
      'inputs[skip_m0]=true',
      '-F',
      'return_run_details=true',
    ]);
    // GitHub answers 204 with no body where run details are unsupported.
    final response = json.trim().isEmpty ? null : jsonDecode(json);
    if (response case {'workflow_run_id': final int runId}) {
      return runId;
    }

    throw StateError(
      'dispatched $ciWorkflow on $branch, but GitHub returned no run id; '
      'find the run with `gh run list --branch $branch --event '
      'workflow_dispatch` and cancel it by hand',
    );
  }

  @override
  Future<void> cancel(int runId) => _gh(['run', 'cancel', '$runId']);

  /// stdout of a successful `gh <command> ... --repo`; stderr may carry
  /// notices.
  Future<String> _gh(List<String> arguments) =>
      _call([...arguments, '--repo', repository]);

  /// `gh api` addresses the repository in its path instead of `--repo`.
  Future<String> _api(List<String> arguments) => _call(['api', ...arguments]);

  Future<String> _call(List<String> arguments) async {
    final result = await _runner('gh', arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        'gh',
        arguments,
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return '${result.stdout}';
  }
}
