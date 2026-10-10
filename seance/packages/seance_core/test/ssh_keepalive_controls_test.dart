import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_peer.dart';

const _defaultInterval = Duration(seconds: 10);
const _customInterval = Duration(seconds: 30);

final _config = ServerConfig(
  id: 'test',
  label: 'test',
  host: 'unused.invalid',
  username: 'user',
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  test('omitting keepalive preserves the existing ten-second timer', () async {
    await _checkTimer(
      (socket) => openAuthenticatedClient(
        config: _config,
        credentials: const SshCredentials.password('test'),
        tofu: TofuVerifier(InMemoryHostKeyStore()),
        // The peer runs a real key exchange, so this now decides whether the
        // handshake continues; host-key trust is not under test here.
        onHostKey: (_) async => true,
        connect: (_, _, _) async => socket,
      ),
      _defaultInterval,
    );
  });

  for (final interval in [_customInterval, null]) {
    test('forwards keepalive interval $interval to the client timer', () async {
      await _checkTimer(
        (socket) => openAuthenticatedClient(
          config: _config,
          credentials: const SshCredentials.password('test'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          // As above: the real handshake needs the host key accepted.
          onHostKey: (_) async => true,
          connect: (_, _, _) async => socket,
          keepAliveInterval: interval,
        ),
        interval,
      );
    });
  }

  for (final interval in [Duration.zero, -_defaultInterval]) {
    test('rejects $interval before connecting', () async {
      var connections = 0;
      await expectLater(
        openAuthenticatedClient(
          config: _config,
          credentials: const SshCredentials.password('test'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => false,
          connect: (_, _, _) async {
            connections++;
            throw StateError('must not connect');
          },
          keepAliveInterval: interval,
        ),
        throwsArgumentError,
      );
      expect(connections, 0);
    });
  }
}

Future<void> _checkTimer(
  Future<(SSHClient, AuthKind)> Function(SSHSocket) open,
  Duration? expectedInterval,
) async {
  final socket = SshPeerSocket();
  final intervals = <Duration>[];
  final timers = <Timer>[];
  SSHClient? client;
  try {
    await runZoned(
      () async {
        final (opened, _) = await open(socket);
        client = opened;
        expect(opened.keepAliveInterval, expectedInterval);
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          intervals.add(duration);
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
    expect(intervals, expectedInterval == null ? isEmpty : [expectedInterval]);
  } finally {
    await client?.close();
    await socket.close();
    expect(timers.every((timer) => !timer.isActive), isTrue);
  }
}
