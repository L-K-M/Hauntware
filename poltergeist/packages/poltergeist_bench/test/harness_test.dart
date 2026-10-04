import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_m0_bench/harness.dart';
import 'package:poltergeist_m0_bench/throughput_attempt.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The live Séance source identity the harness resolves in this worktree.
final liveSeanceRevision = resolveLocalSeanceRevision();

const _treeSha = '0123456789abcdef0123456789abcdef01234567';

void main() {
  test('measurement rows round-trip without changing attribution', () {
    final timestamp = DateTime.utc(2026, 8, 31, 12, 34, 56);
    final result = BenchResult(
      scenario: 'download-1m-lan-hash-off',
      bytes: 1_000_000,
      elapsed: const Duration(microseconds: 4000),
      note: 'verified',
      dartssh2Version: resolvedDartssh2Version,
      seanceRev: liveSeanceRevision,
      rttMs: 101,
      timestampUtc: timestamp,
      host: 'runner',
    );

    final serialized = jsonEncode(result.toJson());
    final decoded = BenchResult.fromJson(
      (jsonDecode(serialized)! as Map).cast<String, Object?>(),
    );

    expect(decoded.toJson(), result.toJson());
    expect(decoded.mbPerSec, 250);
    expect(result.toJson(), result.toJson());
  });

  test('measurement attribution matches the resolved lock', () async {
    final lock = loadYaml(await File('pubspec.lock').readAsString()) as YamlMap;
    final packages = lock['packages']! as YamlMap;
    final dartssh2 = packages['dartssh2']! as YamlMap;

    expect(dartssh2['version'], resolvedDartssh2Version);

    final seancePackages = packages.entries.where(
      (entry) => '${entry.key}'.startsWith('seance_'),
    );
    expect(seancePackages, isNotEmpty);
    final worktree =
        (Process.runSync('git', ['rev-parse', '--show-toplevel']).stdout
                as String)
            .trim();
    final seanceRoot = Directory('$worktree/seance').resolveSymbolicLinksSync();
    for (final package in seancePackages) {
      final details = package.value! as YamlMap;
      // Local sibling source: the lock must pin a path inside the
      // worktree's seance/ component, never an external git revision.
      expect(details['source'], 'path');
      final description = details['description']! as YamlMap;
      final resolved = Directory(
        '${description['path']}',
      ).resolveSymbolicLinksSync();
      expect(
        resolved == seanceRoot || resolved.startsWith('$seanceRoot/'),
        isTrue,
        reason: '${package.key} resolves outside seance/: $resolved',
      );
    }
  });

  test('measurement rows retain raw RTT and transfer evidence', () {
    final rtt = RttEvidence.parse(
      '{"samplesUs":[99000,100000,101000,98000,102000,100000,100000],'
      '"medianMs":100,"capturedAtUtc":"2026-09-01T12:04:00.000Z"}',
    );
    final prime = _attempt(
      phase: ThroughputAttemptPhase.prime,
      reference: 'prime',
      variant: null,
      replicate: null,
      ordinal: null,
      rtt: rtt,
    );
    final warmup = _attempt(
      phase: ThroughputAttemptPhase.warmup,
      reference: 'warmup',
      variant: ThroughputVariant.dartHashOn,
      replicate: ThroughputReplicate.first,
      ordinal: 1,
      rtt: rtt,
      primeReference: prime.reference,
    );
    final trial = _attempt(
      phase: ThroughputAttemptPhase.trial,
      reference: 'trial',
      variant: ThroughputVariant.dartHashOn,
      replicate: ThroughputReplicate.first,
      ordinal: 1,
      rtt: rtt,
      primeReference: prime.reference,
      warmupReference: warmup.reference,
    );
    final result = BenchResult(
      scenario: 'dart-hash-on-download-1mb-rtt100',
      bytes: 1,
      elapsed: const Duration(microseconds: 11),
      dartssh2Version: resolvedDartssh2Version,
      seanceRev: liveSeanceRevision,
      rttEvidence: rtt,
      throughputTrials: [
        ThroughputTrialEvidence(
          sourcePrime: prime,
          warmupSourcePrime: prime,
          warmup: warmup,
          trial: trial,
        ),
      ],
      timestampUtc: DateTime.utc(2026, 9, 1, 12, 5),
      host: 'runner',
    );

    final serialized = jsonEncode(result.toJson());
    final decoded = BenchResult.fromJson(
      (jsonDecode(serialized)! as Map).cast<String, Object?>(),
    );

    expect(decoded.toJson(), result.toJson());
    expect(decoded.rttMs, 100);
    expect(decoded.throughputTrials, hasLength(1));
  });

  group('resolveLocalSeanceRevision', () {
    test('normalizes the environment override to seance@<tree>', () {
      for (final override in [_treeSha, 'seance@$_treeSha', '  $_treeSha  ']) {
        expect(
          resolveLocalSeanceRevision(
            environment: {seanceTreeEnvironmentVariable: override},
          ),
          'seance@$_treeSha',
        );
      }
    });

    test('rejects a malformed environment override', () {
      expect(
        () => resolveLocalSeanceRevision(
          environment: const {
            seanceTreeEnvironmentVariable: 'https://github.com/x/y',
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('resolves the committed seance/ tree of the worktree', () async {
      final repo = await Directory.systemTemp.createTemp('seance-tree-');
      addTearDown(() => repo.delete(recursive: true));
      await _git(repo.path, ['init', '--quiet']);
      await _git(repo.path, ['config', 'user.email', 'test@example.invalid']);
      await _git(repo.path, ['config', 'user.name', 'M0 test']);
      await Directory('${repo.path}/seance/lib').create(recursive: true);
      await File('${repo.path}/seance/lib/x.dart').writeAsString('// x\n');
      await _git(repo.path, ['add', '.']);
      await _git(repo.path, ['commit', '--quiet', '-m', 'tree']);
      final expected = (await _git(repo.path, [
        'rev-parse',
        'HEAD:seance',
      ])).stdout.toString().trim();

      expect(
        resolveLocalSeanceRevision(
          environment: const {},
          repositoryRoot: repo.path,
        ),
        'seance@$expected',
      );

      // A second commit elsewhere does not change the component tree.
      await File('${repo.path}/other.txt').writeAsString('x\n');
      await _git(repo.path, ['add', '.']);
      await _git(repo.path, ['commit', '--quiet', '-m', 'elsewhere']);
      expect(
        resolveLocalSeanceRevision(
          environment: const {},
          repositoryRoot: repo.path,
        ),
        'seance@$expected',
      );
    });

    test('falls back to a rejected local placeholder without a tree', () async {
      final outside = await Directory.systemTemp.createTemp('no-seance-');
      addTearDown(() => outside.delete(recursive: true));

      expect(
        resolveLocalSeanceRevision(
          environment: const {},
          repositoryRoot: outside.path,
        ),
        'local-unresolved-seance-tree',
      );
    });
  });
}

Future<ProcessResult> _git(String repository, List<String> arguments) async {
  final result = await Process.run('git', ['-C', repository, ...arguments]);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.first} failed: ${result.stderr}');
  }

  return result;
}

ThroughputAttempt _attempt({
  required ThroughputAttemptPhase phase,
  required String reference,
  required ThroughputVariant? variant,
  required ThroughputReplicate? replicate,
  required int? ordinal,
  required RttEvidence rtt,
  String? primeReference,
  String? warmupReference,
}) => ThroughputAttempt(
  reference: reference,
  scenario: 'dart-hash-on-download-1mb-rtt100',
  direction: ThroughputLeg.download,
  variant: variant,
  replicate: replicate,
  ordinal: ordinal,
  phase: phase,
  payloadBytes: 1,
  status: ThroughputAttemptStatus.success,
  startedAtUtc: DateTime.utc(2026, 9, 1, 12, 4),
  endedAtUtc: DateTime.utc(2026, 9, 1, 12, 4, 1),
  elapsed: const Duration(microseconds: 10),
  primeReference: primeReference,
  warmupReference: warmupReference,
  rttEvidence: rtt,
  integrity: const ThroughputIntegrityEvidence(
    status: ThroughputIntegrityStatus.verified,
    expectedBytes: 1,
    actualBytes: 1,
    expectedSha256: 'digest',
    actualSha256: 'digest',
    destination: '/tmp/destination',
  ),
);
