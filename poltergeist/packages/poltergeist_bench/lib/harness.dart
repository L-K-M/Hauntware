import 'dart:io';

import 'throughput_attempt.dart';

const resolvedDartssh2Version = '3.0.2';

/// Descriptor prefix for the resolved local Séance source. The live harness
/// no longer pins an external git revision: `seance@<tree>` names the
/// committed `HEAD:seance` subtree — the content the `path:` dependency
/// actually resolves to.
const localSeanceSourcePrefix = 'seance@';

/// Optional environment override supplying the `HEAD:seance` tree id (as
/// `seance@<tree>` or a bare 40-hex tree) where benchmark runs lack git
/// metadata. A malformed override is a configuration error, not a fallback.
const seanceTreeEnvironmentVariable = 'POLTERGEIST_M0_SEANCE_TREE';

final _revisionPattern = RegExp(r'^[0-9a-f]{40}$');
final _seanceSourcePattern = RegExp(r'^(?:seance@)?([0-9a-f]{40})$');

/// The deterministic identity of the shared local Séance source for the
/// live harness: `seance@<tree>` where `<tree>` is `git rev-parse
/// HEAD:seance` in the enclosing worktree. Frozen M0 evidence retains its
/// measured revisions; only live runs use this resolution. Environments
/// with no tree metadata fall back to a `local-` placeholder that
/// aggregation rejects, so an unidentified source can never be reported
/// as a real dependency revision.
String resolveLocalSeanceRevision({
  Map<String, String>? environment,
  String? repositoryRoot,
}) {
  final override =
      (environment ?? Platform.environment)[seanceTreeEnvironmentVariable];
  if (override != null && override.trim().isNotEmpty) {
    final match = _seanceSourcePattern.firstMatch(override.trim());
    if (match == null) {
      throw ArgumentError.value(
        override,
        seanceTreeEnvironmentVariable,
        'expected `seance@<40-hex>` or a 40-hex tree id',
      );
    }
    return '$localSeanceSourcePrefix${match.group(1)}';
  }
  final tree = _gitObjectRevision(repositoryRoot, 'HEAD:seance');
  if (tree == null) return 'local-unresolved-seance-tree';

  return '$localSeanceSourcePrefix$tree';
}

/// The enclosing worktree's HEAD commit, or null without git metadata.
/// Local runs attribute the real repository commit instead of claiming an
/// external pin.
String? resolveHeadRevision({String? repositoryRoot}) =>
    _gitObjectRevision(repositoryRoot, 'HEAD');

String? _gitObjectRevision(String? repositoryRoot, String revision) {
  final result = Process.runSync('git', [
    '-C',
    repositoryRoot ?? Directory.current.path,
    'rev-parse',
    '--verify',
    revision,
  ]);
  if (result.exitCode != 0) return null;

  final sha = result.stdout.toString().trim();
  return _revisionPattern.hasMatch(sha) ? sha : null;
}

/// One attributable measurement row. Rates stay derived from raw values.
class BenchResult {
  final String scenario;
  final int bytes;
  final Duration elapsed;
  final String? note;
  final String dartssh2Version;
  final String seanceRev;
  final int? rttMs;
  final RttEvidence? rttEvidence;
  final List<ThroughputTrialEvidence>? throughputTrials;
  final DateTime timestampUtc;
  final String host;

  BenchResult({
    required this.scenario,
    required this.bytes,
    required this.elapsed,
    this.note,
    required this.dartssh2Version,
    required this.seanceRev,
    int? rttMs,
    this.rttEvidence,
    List<ThroughputTrialEvidence>? throughputTrials,
    required this.timestampUtc,
    required this.host,
  }) : rttMs = rttMs ?? rttEvidence?.medianMs,
       throughputTrials = throughputTrials == null
           ? null
           : List.unmodifiable(throughputTrials) {
    if (rttMs != null &&
        rttEvidence != null &&
        rttMs != rttEvidence!.medianMs) {
      throw ArgumentError('RTT scalar and evidence disagree.');
    }
  }

  factory BenchResult.capture({
    required String scenario,
    required int bytes,
    required Duration elapsed,
    String? note,
    int? rttMs,
    RttEvidence? rttEvidence,
    List<ThroughputTrialEvidence>? throughputTrials,
    String? seanceRev,
  }) => BenchResult(
    scenario: scenario,
    bytes: bytes,
    elapsed: elapsed,
    note: note,
    dartssh2Version: resolvedDartssh2Version,
    seanceRev: seanceRev ?? resolveLocalSeanceRevision(),
    rttMs: rttMs,
    rttEvidence: rttEvidence,
    throughputTrials: throughputTrials,
    timestampUtc: DateTime.now().toUtc(),
    host: Platform.localHostname,
  );

  factory BenchResult.fromJson(Map<String, Object?> json) {
    final rawRttEvidence = json['rttEvidence'];
    final rawTrials = json['throughputTrials'];
    return BenchResult(
      scenario: json['scenario']! as String,
      bytes: json['bytes']! as int,
      elapsed: Duration(microseconds: json['elapsedUs']! as int),
      note: json['note'] as String?,
      dartssh2Version: json['dartssh2Version']! as String,
      seanceRev: json['seanceRev']! as String,
      rttMs: json['rttMs'] as int?,
      rttEvidence: rawRttEvidence == null
          ? null
          : RttEvidence.fromJson(
              (rawRttEvidence as Map).cast<String, Object?>(),
            ),
      throughputTrials: rawTrials == null
          ? null
          : (rawTrials as List<Object?>)
                .map(
                  (trial) => ThroughputTrialEvidence.fromJson(
                    (trial! as Map).cast<String, Object?>(),
                  ),
                )
                .toList(),
      timestampUtc: DateTime.parse(json['timestampUtc']! as String),
      host: json['host']! as String,
    );
  }

  double get mbPerSec => bytes / elapsed.inMicroseconds;

  Map<String, Object?> toJson() => {
    'scenario': scenario,
    'bytes': bytes,
    'dartssh2Version': dartssh2Version,
    'seanceRev': seanceRev,
    'rttMs': rttMs,
    if (rttEvidence != null) 'rttEvidence': rttEvidence!.toJson(),
    'elapsedUs': elapsed.inMicroseconds,
    'note': note,
    'timestampUtc': timestampUtc.toIso8601String(),
    'host': host,
    if (throughputTrials != null)
      'throughputTrials': throughputTrials!
          .map((trial) => trial.toJson())
          .toList(),
  };
}

class BenchRunFailure implements Exception {
  final String message;
  final List<BenchResult> results;

  const BenchRunFailure(this.message, this.results);

  @override
  String toString() => message;
}
