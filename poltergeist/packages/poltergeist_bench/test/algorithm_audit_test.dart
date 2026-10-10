import 'package:poltergeist_m0_bench/algorithm_audit.dart';
import 'package:poltergeist_m0_bench/config.dart';
import 'package:poltergeist_m0_bench/ssh_driver.dart';
import 'package:test/test.dart';

void main() {
  test(
    'audits forced AES-GCM and independent modern-algorithm support',
    () async {
      final forcedCiphers = <String>[];
      final forcedHostKeys = <String>[];
      final results = await runAlgorithmAudit(
        _config,
        probe: (endpoint, {algorithms}) async {
          forcedCiphers.addAll(
            algorithms?.cipher.map((cipher) => cipher.name) ?? const [],
          );
          forcedHostKeys.addAll(
            algorithms?.hostkey.map((hostKey) => hostKey.name) ?? const [],
          );
          return const AlgorithmAuditResult(
            outcome: AlgorithmAuditOutcome.connected,
            elapsed: Duration.zero,
            detail: 'connected',
          );
        },
      );

      expect(
        forcedCiphers,
        containsAll(['aes128-gcm@openssh.com', 'aes256-gcm@openssh.com']),
      );
      expect(forcedHostKeys, containsAll(['rsa-sha2-256', 'rsa-sha2-512']));
      expect(
        results.map((result) => result.scenario),
        containsAll([
          'algorithm-legacy-default',
          'algorithm-aes128-gcm',
          'algorithm-aes256-gcm',
          'algorithm-rsa-sha2-256',
          'algorithm-rsa-sha2-512',
          'algorithm-client-support-chacha20-poly1305',
          'algorithm-client-support-curve25519',
          'algorithm-client-support-mlkem768x25519',
        ]),
      );
    },
  );

  test('records chacha20-poly1305 support and the ML-KEM gap', () async {
    final results = await runAlgorithmAudit(
      _config,
      probe: (endpoint, {algorithms}) async => const AlgorithmAuditResult(
        outcome: AlgorithmAuditOutcome.connected,
        elapsed: Duration.zero,
        detail: 'connected',
      ),
    );
    String? note(String suffix) => results
        .singleWhere(
          (result) => result.scenario == 'algorithm-client-support-$suffix',
        )
        .note;

    // M0 measured dartssh2 3.0.2, which lacked chacha20-poly1305, so the
    // committed report records supported=false. dartssh2 3.2.0 added it.
    expect(note('chacha20-poly1305'), startsWith('supported=true;'));
    expect(note('curve25519'), startsWith('supported=true;'));
    // mlkem768x25519-sha256 is still missing in 4.1.0, so ML-KEM-only
    // servers remain out of reach.
    expect(note('mlkem768x25519'), startsWith('supported=false;'));
  });
}

const _config = BenchConfig(
  endpoint: BenchEndpoint(
    host: '127.0.0.1',
    port: 2201,
    username: 'poltergeist',
    password: 'test',
  ),
  remoteRoot: '/home/poltergeist/bench',
  identityFile: 'unused',
  outputFile: 'unused',
  linkName: 'lan',
  fixtureRoot: 'unused',
  uploadRoot: 'unused',
  rttEvidence: null,
);
