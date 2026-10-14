import 'dart:async';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:test/test.dart';

import 'fixtures/ssh_config_fixture.dart';

void main() {
  group('IsolateEngineClient (03 D18)', () {
    test('spawn completes the Hello handshake', () async {
      final client = await IsolateEngineClient.spawn();
      addTearDown(client.shutdown);

      // spawn() returns only after EngineReady, so a ready client here is
      // the assertion; the rejected probe below proves events still flow.
      client.send(const Connect('srv-1'));
      final event = await client.events.first;
      expect(event, isA<RequestRejected>());
      expect((event as RequestRejected).requestName, 'Connect');
    });

    test('unimplemented requests get RequestRejected', () async {
      final client = await IsolateEngineClient.spawn();
      addTearDown(client.shutdown);

      client
        ..send(const EnrollSync())
        ..send(const RunSyncRound())
        ..send(const PlanAction(ActionIntent(serverId: 'srv-1', action: 'x')));

      final names = await client.events
          .take(3)
          .map((e) => (e as RequestRejected).requestName)
          .toList();
      expect(names, ['EnrollSync', 'RunSyncRound', 'PlanAction']);
    });

    test('Subscribe/Unsubscribe are accepted without a reply', () async {
      final client = await IsolateEngineClient.spawn();
      addTearDown(client.shutdown);

      client
        ..send(
          const Subscribe(
            serverId: 'srv-1',
            collectors: {Collector.overview},
            cadence: Duration(seconds: 2),
          ),
        )
        ..send(const Unsubscribe('srv-1'))
        // The probe proves the engine handled both silently instead of
        // dying or rejecting them.
        ..send(const Connect('probe'));

      final event = await client.events.first;
      expect((event as RequestRejected).requestName, 'Connect');
    });

    test('ImportSshConfig answers the fleet, then the counts', () async {
      final client = await IsolateEngineClient.spawn();
      addTearDown(client.shutdown);

      final events = StreamIterator(client.events);
      client.send(const ImportSshConfig(sshConfigFixture));

      // CN-19: the engine isolate parsed the text; the UI receives only
      // plain entries, and the fleet arrives before the answer.
      expect(await events.moveNext(), isTrue);
      final fleet = events.current as CatalogReplaced;
      expect(fleet.entries.map((e) => e.label), sshConfigFixtureEntries);
      expect(fleet.entries.first.port, 2222);
      // What the engine parsed, not only which hosts it found.
      final byLabel = {for (final e in fleet.entries) e.label: e};
      expect(byLabel['web-1']!.host, 'web-1.example.com');
      expect(byLabel['web-1']!.user, 'deploy');
      // `User=admin`: the `Key=value` form; no HostName means the alias.
      expect(byLabel['bastion']!.user, 'admin');
      expect(byLabel['bastion']!.host, 'bastion');
      // Include is not followed: the labels above hold no included host,
      // and the block that names one keeps its own HostName.
      expect(byLabel['legacy']!.host, 'legacy.example.com');
      expect(byLabel['v6']!.host, '2001:db8::1');
      expect(await events.moveNext(), isTrue);
      final answer = events.current as SshConfigImported;
      expect(answer.importedCount, sshConfigFixtureEntries.length);
      expect(answer.skippedCount, sshConfigFixtureSkipped);

      // A second import replaces the first one's entries.
      client.send(const ImportSshConfig('Host only\n  HostName 192.0.2.7\n'));
      expect(await events.moveNext(), isTrue);
      final replaced = events.current as CatalogReplaced;
      expect(replaced.entries.map((e) => e.serverId), ['ssh-config:only']);
      expect(await events.moveNext(), isTrue);
      expect((events.current as SshConfigImported).importedCount, 1);

      // A config without hosts empties the imported part of the fleet.
      client.send(const ImportSshConfig('Host *\n  User nobody\n'));
      expect(await events.moveNext(), isTrue);
      expect((events.current as CatalogReplaced).entries, isEmpty);
      expect(await events.moveNext(), isTrue);
      final none = events.current as SshConfigImported;
      expect(none.importedCount, 0);
      expect(none.skippedCount, 0);
      await events.cancel();
    });

    test('send after shutdown throws; shutdown is idempotent', () async {
      final client = await IsolateEngineClient.spawn();
      await client.shutdown();
      await client.shutdown();

      expect(() => client.send(const Connect('srv-1')), throwsStateError);
    });

    test('events close when the engine exits', () async {
      final client = await IsolateEngineClient.spawn();
      final done = expectLater(client.events.toList(), completion(isEmpty));
      await client.shutdown();
      await done;
    });
  });

  group('engineMain raw messages', () {
    // A spawned engine plus a StreamIterator over its port: one subscription
    // keeps the handshake and later replies readable in order.
    Future<
      ({
        StreamIterator<Object?> stream,
        SendPort commands,
        Isolate isolate,
        ReceivePort port,
      })
    >
    spawn() async {
      final port = ReceivePort();
      final isolate = await Isolate.spawn(engineMain, port.sendPort);
      final stream = StreamIterator<Object?>(port);
      await stream.moveNext();
      return (
        stream: stream,
        commands: stream.current as SendPort,
        isolate: isolate,
        port: port,
      );
    }

    Future<EngineEvent> nextEvent(StreamIterator<Object?> stream) async {
      while (await stream.moveNext()) {
        if (stream.current is EngineEvent) {
          return stream.current as EngineEvent;
        }
      }
      throw StateError('engine stopped before an event arrived');
    }

    test('a non-EngineRequest message is rejected, not fatal', () async {
      final engine = await spawn();
      addTearDown(() {
        engine.isolate.kill();
        engine.port.close();
      });

      engine.commands.send('not a request');
      expect(await nextEvent(engine.stream), isA<RequestRejected>());
    });

    test('Hello with a foreign protocol version is rejected', () async {
      final engine = await spawn();
      addTearDown(() {
        engine.isolate.kill();
        engine.port.close();
      });

      engine.commands.send(const Hello(protocolVersion: -1));
      engine.commands.send(const Hello());

      expect(await nextEvent(engine.stream), isA<RequestRejected>());
      expect(await nextEvent(engine.stream), isA<EngineReady>());
    });

    test('spawn fails when the engine exits before its command port', () async {
      await expectLater(
        IsolateEngineClient.spawn(entryPoint: _exitAtOnce),
        throwsStateError,
      );
    });

    test('spawn fails when the engine refuses Hello', () async {
      await expectLater(
        IsolateEngineClient.spawn(entryPoint: _refuseHello),
        throwsStateError,
      );
    });
  });
}

/// An engine that dies before it hands over its command port.
void _exitAtOnce(SendPort uiPort) => Isolate.exit();

/// An engine that answers the handshake with a refusal.
void _refuseHello(SendPort uiPort) {
  final commands = ReceivePort();
  uiPort.send(commands.sendPort);
  commands.listen((_) => uiPort.send(const RequestRejected('Hello', 'no')));
}
