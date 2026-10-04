import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

const _targetId = 'target';
const _middleId = 'middle';
const _outerId = 'outer';
const _maximumJumpHosts = 16;
const _firstReconnectDelay = Duration(seconds: 1);

ServerConfig _server(String id, {String? jumpHostId}) => ServerConfig(
  id: id,
  label: id,
  host: '$id.example.com',
  port: 22,
  username: 'test',
  authMethod: AuthMethod.password,
  jumpHostId: jumpHostId,
  createdAt: 0,
  updatedAt: 0,
);

void _addRoute(PoolHarness harness) {
  harness
    ..addServer(_targetId, host: 'target.example.com', jumpHostId: _middleId)
    ..addServer(_middleId, host: 'middle.example.com', jumpHostId: _outerId)
    ..addServer(_outerId, host: 'outer.example.com');
}

Matcher get _disconnected => throwsA(
  isA<RemoteFileException>().having(
    (error) => error.kind,
    'kind',
    RemoteFileErrorKind.disconnected,
  ),
);

Future<void> _expectInvalidRoute(PoolHarness harness, Matcher message) async {
  await expectLater(
    harness.manager.leaseTransferChannel(_targetId),
    throwsA(
      isA<SshConnectException>().having(
        (error) => error.message,
        'message',
        message,
      ),
    ),
  );

  expect(harness.credentialResolveCalls, 0);
  expect(harness.opener.calls, isEmpty);
  await harness.manager.disconnectServer(_targetId);
}

void main() {
  group('route configuration validation', () {
    test('rejects a missing jump host before credentials or opening', () async {
      final harness = PoolHarness()
        ..addServer(_targetId, jumpHostId: 'missing');

      await _expectInvalidRoute(
        harness,
        contains('Could not resolve jump host "missing"'),
      );
    });

    test('rejects a cycle before credentials or opening', () async {
      final harness = PoolHarness()
        ..addServer(_targetId, jumpHostId: _middleId)
        ..addServer(_middleId, jumpHostId: _targetId);

      await _expectInvalidRoute(harness, contains('contains a cycle'));
    });

    test(
      'rejects more than 16 jump hosts before credentials or opening',
      () async {
        final harness = PoolHarness()
          ..addServer(_targetId, jumpHostId: 'jump-0');
        for (var index = 0; index <= _maximumJumpHosts; index++) {
          harness.addServer(
            'jump-$index',
            jumpHostId: index == _maximumJumpHosts ? null : 'jump-${index + 1}',
          );
        }

        await _expectInvalidRoute(
          harness,
          contains('exceeds $_maximumJumpHosts hops'),
        );
      },
    );

    test(
      'rejects a resolver id mismatch before credentials or opening',
      () async {
        final harness = PoolHarness()
          ..addServer(_targetId, jumpHostId: 'requested')
          ..addServer('actual', host: 'actual.example.com');
        harness.servers['requested'] = harness.servers.remove('actual')!;

        await _expectInvalidRoute(
          harness,
          contains('resolved to a different server'),
        );
      },
    );
  });

  test('resolves every route credential before invoking the opener', () async {
    final servers = <String, ServerConfig>{
      _targetId: _server(_targetId, jumpHostId: _middleId),
      _middleId: _server(_middleId, jumpHostId: _outerId),
      _outerId: _server(_outerId),
    };
    final opener = FakeTransportOpener();
    final outerResolutionStarted = Completer<void>();
    final releaseOuterResolution = Completer<void>();
    final resolutionOrder = <String>[];
    final manager = PooledConnectionManager(
      resolveServer: (serverId) async => servers[serverId]!,
      resolveCredentials: (config, scope) async {
        resolutionOrder.add(config.id);
        if (config.id == _outerId) {
          outerResolutionStarted.complete();
          await releaseOuterResolution.future;
        }

        return ResolvedCredentials(
          credentials: SshCredentials.password('${config.id}-secret'),
          origin: CredentialOrigin.stored,
        );
      },
      tofu: TofuVerifier(FakeHostKeyStore()),
      onHostKey: (_) async => true,
      openTransport: opener.opener,
    );

    final pending = manager.leaseTransferChannel(_targetId);
    await outerResolutionStarted.future;

    expect(resolutionOrder, [_targetId, _middleId, _outerId]);
    expect(opener.calls, isEmpty);

    releaseOuterResolution.complete();
    final lease = await pending;
    final call = opener.calls.single;
    expect(call.credentials.password, 'target-secret');
    expect(call.jumpHosts.map((host) => host.config.id), [_middleId, _outerId]);
    expect(call.jumpHosts.map((host) => host.credentials.password), [
      'middle-secret',
      'outer-secret',
    ]);

    await lease.release();
    await manager.disconnectServer(_targetId);
  });

  test('growth reuses cached target and jump-host credentials', () async {
    final harness = PoolHarness();
    _addRoute(harness);
    final pane = await harness.manager.openBrowseChannel(
      _targetId,
      paneTabId: 'tab',
    );

    final leases = await Future.wait([
      for (var index = 0; index < 8; index++)
        harness.manager.leaseTransferChannel(_targetId),
    ]);

    expect(harness.resolveCalls, 3);
    expect(harness.credentialResolveCalls, 3);
    expect(harness.opener.calls, hasLength(2));
    final initial = harness.opener.calls.first;
    final growth = harness.opener.calls.last;
    expect(growth.prompting, ConnectPrompting.disabled);
    expect(growth.credentials, same(initial.credentials));
    expect(growth.jumpHosts, hasLength(2));
    for (var index = 0; index < growth.jumpHosts.length; index++) {
      expect(growth.jumpHosts[index], same(initial.jumpHosts[index]));
    }

    for (final lease in leases) {
      await lease.release();
    }
    await pane.close();
    await harness.manager.disconnectServer(_targetId);
  });

  test('a prompted jump-host credential caps route growth', () async {
    final harness = PoolHarness(
      policy: const PoolPolicy(
        maxTransports: 2,
        maxTransferChannelsPerTransport: 1,
        maxChannelsPerTransport: 2,
      ),
      credentialsFor: (config) => ResolvedCredentials(
        credentials: SshCredentials.password('${config.id}-secret'),
        origin: config.id == _outerId
            ? CredentialOrigin.prompted
            : CredentialOrigin.stored,
      ),
    );
    _addRoute(harness);
    final pane = await harness.manager.openBrowseChannel(
      _targetId,
      paneTabId: 'tab',
    );
    final first = await harness.manager.leaseTransferChannel(_targetId);
    final waiting = harness.manager.leaseTransferChannel(_targetId);
    await pumpEventQueue();

    expect(harness.opener.calls, hasLength(1));
    await first.release();
    final second = await waiting;

    await second.release();
    await pane.close();
    await harness.manager.disconnectServer(_targetId);
  });

  test('a jump-host keyboard challenge caps route growth', () async {
    final harness = PoolHarness(
      opener: FakeTransportOpener(
        keyboardChallengeServerId: _outerId,
      ),
      policy: const PoolPolicy(
        maxTransports: 2,
        maxTransferChannelsPerTransport: 1,
        maxChannelsPerTransport: 2,
      ),
    );
    _addRoute(harness);
    final pane = await harness.manager.openBrowseChannel(
      _targetId,
      paneTabId: 'tab',
    );
    final first = await harness.manager.leaseTransferChannel(_targetId);
    final waiting = harness.manager.leaseTransferChannel(_targetId);
    await pumpEventQueue();

    expect(harness.keyboardCalls, 1);
    expect(harness.opener.calls, hasLength(1));
    await first.release();
    final second = await waiting;

    await second.release();
    await pane.close();
    await harness.manager.disconnectServer(_targetId);
  });

  test(
    'routed reconnect skips probing and reuses cached route credentials',
    () {
      fakeAsync((time) {
        final prober = FakeReconnectProber()..status = ProbeStatus.offline;
        final harness = PoolHarness(prober: prober);
        _addRoute(harness);
        final pane = browsePane(time, harness, 'tab', server: _targetId);
        final initial = harness.opener.calls.single;

        harness.opener.transports.single.simulateExternalDeath();
        time.flushMicrotasks();
        time.elapse(_firstReconnectDelay);
        time.flushMicrotasks();

        expect(prober.calls, 0);
        expect(harness.resolveCalls, 3);
        expect(harness.credentialResolveCalls, 3);
        expect(harness.opener.calls, hasLength(2));
        final reconnect = harness.opener.calls.last;
        expect(reconnect.prompting, ConnectPrompting.disabled);
        expect(reconnect.credentials, same(initial.credentials));
        expect(reconnect.jumpHosts, hasLength(2));
        for (var index = 0; index < reconnect.jumpHosts.length; index++) {
          expect(reconnect.jumpHosts[index], same(initial.jumpHosts[index]));
        }
        expect(pane.fs, isA<RemoteFileSystem>());

        completeWithoutTimers(time, pane.close());
        completeWithoutTimers(
          time,
          harness.manager.disconnectServer(_targetId),
        );
        expect(time.pendingTimers, isEmpty);
      });
    },
  );

  test('a routed auth challenge re-resolves every credential', () {
    fakeAsync((time) {
      final opener = FakeTransportOpener(growthRequiresChallenge: true);
      final harness = PoolHarness(opener: opener);
      _addRoute(harness);
      final pane = browsePane(time, harness, 'tab', server: _targetId);

      opener.transports.single.simulateExternalDeath();
      time.flushMicrotasks();
      time.elapse(_firstReconnectDelay);
      time.flushMicrotasks();

      expect(harness.credentialResolveCalls, 3);
      expect(opener.calls, hasLength(2));
      expect(opener.calls.last.prompting, ConnectPrompting.disabled);

      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();

      expect(harness.resolveCalls, 3);
      expect(harness.credentialResolveCalls, 6);
      expect(opener.calls, hasLength(3));
      expect(opener.calls.last.prompting, ConnectPrompting.enabled);
      expect(opener.calls.last.jumpHosts, hasLength(2));
      expect(pane.fs, isA<RemoteFileSystem>());

      completeWithoutTimers(time, pane.close());
      completeWithoutTimers(
        time,
        harness.manager.disconnectServer(_targetId),
      );
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('a cancelled routed reconnect stops between credential reads', () {
    fakeAsync((time) {
      final targetResolutionStarted = Completer<void>();
      final releaseTargetResolution = Completer<void>();
      final reconnectCredentialIds = <String>[];
      var holdReconnect = false;
      final opener = FakeTransportOpener(growthRequiresChallenge: true);
      final harness = PoolHarness(
        opener: opener,
        credentialsFor: (config) async {
          if (!holdReconnect) {
            return ResolvedCredentials(
              credentials: SshCredentials.password('${config.id}-secret'),
              origin: CredentialOrigin.stored,
            );
          }

          reconnectCredentialIds.add(config.id);
          if (config.id == _targetId) {
            targetResolutionStarted.complete();
            await releaseTargetResolution.future;
          }

          return ResolvedCredentials(
            credentials: SshCredentials.password('${config.id}-secret'),
            origin: CredentialOrigin.stored,
          );
        },
      );
      _addRoute(harness);
      final pane = browsePane(time, harness, 'tab', server: _targetId);

      opener.transports.single.simulateExternalDeath();
      time.flushMicrotasks();
      time.elapse(_firstReconnectDelay);
      time.flushMicrotasks();
      expect(opener.calls, hasLength(2));

      holdReconnect = true;
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(targetResolutionStarted.isCompleted, isTrue);
      expect(reconnectCredentialIds, [_targetId]);

      completeWithoutTimers(time, harness.manager.disconnectServer(_targetId));
      releaseTargetResolution.complete();
      time.flushMicrotasks();

      // Cancellation dismisses the active prompt and must not start another.
      expect(reconnectCredentialIds, [_targetId]);
      expect(opener.calls, hasLength(2));
      completeWithoutTimers(time, pane.close());
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('disconnect after route credentials does not dismiss their scope', () {
    fakeAsync((time) {
      final gate = Completer<void>();
      final opener = FakeTransportOpener()..connectGate = gate;
      final harness = PoolHarness(opener: opener);
      _addRoute(harness);
      final connect = harness.manager.openBrowseChannel(
        _targetId,
        paneTabId: 'tab',
      );
      final failed = expectLater(connect, _disconnected);
      time.flushMicrotasks();

      expect(harness.credentialResolveCalls, 3);
      expect(harness.resolutionScopes, hasLength(3));
      expect(
        harness.resolutionScopes,
        everyElement(same(harness.resolutionScopes.first)),
      );
      expect(opener.transports, hasLength(1));

      var dismissed = false;
      unawaited(
        harness.resolutionScopes.first.dismissed.then((_) => dismissed = true),
      );
      completeWithoutTimers(time, harness.manager.disconnectServer(_targetId));
      expect(dismissed, isFalse);

      gate.complete();
      completeWithoutTimers(time, failed);
      expect(dismissed, isFalse);
      expect(opener.transports.single.closed, isTrue);
      expect(time.pendingTimers, isEmpty);
    });
  });
}
