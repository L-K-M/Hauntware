// 02 §10's dialog order — trust before secrets — at the pool layer: a
// first connect to an unpinned endpoint runs the host-key preflight
// before the credential resolver can prompt, a pinned endpoint skips it,
// and a rejected key never reaches the resolver at all. The real
// preflight over OpenSSH is exercised by the env-gated
// engine_transfer_sshd_test.

import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _fingerprint = 'SHA256:presented';

void main() {
  late List<String> order;

  /// The fake preflight follows the production sequence: check, prompt
  /// on anything but trusted, pin on approval, fail on rejection.
  SshHostKeyPreflight preflight() =>
      ({
        required ServerConfig config,
        required TofuVerifier tofu,
        required HostKeyPrompter onHostKey,
        Duration timeout = const Duration(seconds: 15),
        SshConnectionLog? log,
      }) async {
        order.add('preflight');
        final presented = HostKey(
          host: config.host,
          port: config.port,
          type: 'ssh-ed25519',
          fingerprintSha256: _fingerprint,
          pinnedAt: 0,
        );
        final decision = await tofu.check(presented);
        if (decision.isTrusted) return;
        if (!await onHostKey(decision)) {
          throw SshConnectException(
            'The host key was not accepted.',
            StateError('host key rejected'),
            log ?? SshConnectionLog(),
          );
        }
        await tofu.pin(presented);
      };

  PoolHarness harness({bool accept = true}) {
    final built = PoolHarness(hostKeyPreflight: preflight())
      ..addServer('s1')
      ..onHostKey = (decision) async {
        order.add('hostKey:${decision.verdict.name}');
        return accept;
      };
    addTearDown(() => built.manager.disconnectServer('s1'));
    return built;
  }

  setUp(() => order = []);

  test('an unpinned endpoint asks for trust before any credential', () async {
    final pool = harness();
    final lease = await pool.manager.leaseTransferChannel('s1');
    // The resolver ran after the prompt; the authenticated connect found
    // the key pinned and asked nothing more.
    expect(order, ['preflight', 'hostKey:firstUse']);
    expect(pool.credentialResolveCalls, 1);
    expect(await pool.store.get('example.com', 22), isNotNull);
    await lease.release();
  });

  test('the resolver has not run when the trust prompt appears', () async {
    late int resolvedAtPrompt;
    final pool = harness();
    pool.onHostKey = (decision) async {
      resolvedAtPrompt = pool.credentialResolveCalls;
      return true;
    };
    final lease = await pool.manager.leaseTransferChannel('s1');
    expect(resolvedAtPrompt, 0);
    await lease.release();
  });

  test('a pinned endpoint skips the preflight', () async {
    final pool = harness();
    await pool.store.put(
      const HostKey(
        host: 'example.com',
        port: 22,
        type: 'ssh-ed25519',
        fingerprintSha256: _fingerprint,
        pinnedAt: 0,
      ),
    );
    final lease = await pool.manager.leaseTransferChannel('s1');
    expect(order, isEmpty);
    await lease.release();
  });

  test('a config edit cannot split one first-connect snapshot', () async {
    final preflightStarted = Completer<void>();
    final releasePreflight = Completer<void>();
    final pool = PoolHarness(
      hostKeyPreflight:
          ({
            required ServerConfig config,
            required TofuVerifier tofu,
            required HostKeyPrompter onHostKey,
            Duration timeout = const Duration(seconds: 15),
            SshConnectionLog? log,
          }) async {
            preflightStarted.complete();
            await releasePreflight.future;
          },
      credentialsFor: (config) => ResolvedCredentials(
        credentials: switch (config.authMethod) {
          AuthMethod.password => const SshCredentials.password('old-secret'),
          AuthMethod.agent => const SshCredentials.agent(),
          AuthMethod.privateKey => const SshCredentials.privateKey('old-key'),
        },
        origin: CredentialOrigin.stored,
      ),
    )..addServer('s1', authMethod: AuthMethod.password);
    addTearDown(() => pool.manager.disconnectServer('s1'));

    final pending = pool.manager.leaseTransferChannel('s1');
    await preflightStarted.future;

    final replacement = ServerConfig(
      id: 's1',
      label: 's1',
      host: 'example.com',
      port: 22,
      username: 'test',
      authMethod: AuthMethod.agent,
      createdAt: 0,
      updatedAt: 1,
    );
    pool.servers['s1'] = replacement;
    pool.manager.updateServerConfig('s1', replacement);
    releasePreflight.complete();

    final lease = await pending;
    final open = pool.opener.calls.single;
    expect(open.config.authMethod, AuthMethod.password);
    expect(open.credentials.method, AuthMethod.password);
    await lease.release();
  });

  test('a rejected key never reaches the credential resolver', () async {
    final pool = harness(accept: false);
    await expectLater(
      pool.manager.leaseTransferChannel('s1'),
      throwsA(isA<SshConnectException>()),
    );
    expect(order, ['preflight', 'hostKey:firstUse']);
    expect(pool.credentialResolveCalls, 0);
    expect(pool.opener.calls, isEmpty);
    final status = await pool.manager.watchServer('s1').first;
    expect(status.state, ServerConnectionState.disconnected);
    expect(status.detail, contains('not accepted'));
  });

  test('a jump route skips the unsafe direct host-key preflight', () async {
    var preflightCalls = 0;
    final pool =
        PoolHarness(
            hostKeyPreflight:
                ({
                  required ServerConfig config,
                  required TofuVerifier tofu,
                  required HostKeyPrompter onHostKey,
                  Duration timeout = const Duration(seconds: 15),
                  SshConnectionLog? log,
                }) async {
                  preflightCalls++;
                },
          )
          ..addServer('s1', jumpHostId: 'bastion')
          ..addServer('bastion', host: 'bastion.example.com');
    addTearDown(() => pool.manager.disconnectServer('s1'));

    final lease = await pool.manager.leaseTransferChannel('s1');

    expect(preflightCalls, 0);
    expect(pool.credentialResolveCalls, 2);
    expect(pool.opener.calls, hasLength(1));
    await lease.release();
  });
}
