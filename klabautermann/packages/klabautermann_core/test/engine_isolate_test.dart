import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_import_store.dart'
    show sshConfigImportsFileName, sshConfigImportsSchemaVersion;
import 'package:test/test.dart';

import 'fixtures/ssh_config_fixture.dart';

void main() {
  late Directory support;
  late File importsFile;

  setUp(() {
    support = Directory.systemTemp.createTempSync('klab-engine-');
    importsFile = File('${support.path}/$sshConfigImportsFileName');
  });

  tearDown(() => support.deleteSync(recursive: true));

  /// A real engine isolate over [directory] (the test's support directory
  /// by default), shut down after the test.
  Future<IsolateEngineClient> spawnEngine({String? directory}) async {
    final client = await IsolateEngineClient.spawn(
      supportDirectory: directory ?? support.path,
    );
    addTearDown(client.shutdown);
    return client;
  }

  /// The client's events after the fleet the engine starts with, which is
  /// always the first one. Cancel the iterator before a mid-test shutdown:
  /// shutdown waits for every listener to see the stream close, and an
  /// iterator between moves holds its subscription paused.
  Future<({StreamIterator<EngineEvent> events, CatalogReplaced fleet})> started(
    IsolateEngineClient client,
  ) async {
    final events = StreamIterator(client.events);
    addTearDown(events.cancel);
    expect(await events.moveNext(), isTrue);
    return (events: events, fleet: events.current as CatalogReplaced);
  }

  Future<EngineEvent> next(StreamIterator<EngineEvent> events) async {
    expect(await events.moveNext(), isTrue, reason: 'the engine stopped');
    return events.current;
  }

  group('IsolateEngineClient (03 D18)', () {
    test('spawn completes the Hello handshake', () async {
      final client = await spawnEngine();

      // spawn() returns only after EngineReady, so a ready client here is
      // the assertion; the rejected probe below proves events still flow.
      expect(client.ready.protocolVersion, kEngineProtocolVersion);
      expect(client.ready.importStoreIssue, isNull);
      final (:events, :fleet) = await started(client);
      expect(fleet.entries, isEmpty, reason: 'nothing imported yet');
      client.send(const Connect('srv-1'));
      final event = await next(events);
      expect(event, isA<RequestRejected>());
      expect((event as RequestRejected).requestName, 'Connect');
    });

    test('the startup fleet waits for a listener that comes late', () async {
      final client = await spawnEngine();
      // Long enough for the engine's startup events to arrive with nobody
      // listening: a plain broadcast stream would drop them.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      client.send(const Connect('probe'));

      final events = await client.events.take(2).toList();
      expect(events.first, isA<CatalogReplaced>());
      expect((events.last as RequestRejected).requestName, 'Connect');
    });

    test('unimplemented requests get RequestRejected', () async {
      final client = await spawnEngine();
      final (:events, fleet: _) = await started(client);

      client
        ..send(const EnrollSync())
        ..send(const RunSyncRound())
        ..send(const PlanAction(ActionIntent(serverId: 'srv-1', action: 'x')))
        // Accepted once links land; until then nothing would act on it.
        ..send(const SetAppActivity(AppActivity.background));

      final names = [
        for (var i = 0; i < 4; i++)
          ((await next(events)) as RequestRejected).requestName,
      ];
      expect(names, [
        'EnrollSync',
        'RunSyncRound',
        'PlanAction',
        'SetAppActivity',
      ]);
    });

    test('Subscribe/Unsubscribe are accepted without a reply', () async {
      final client = await spawnEngine();
      final (:events, fleet: _) = await started(client);

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

      final event = await next(events);
      expect((event as RequestRejected).requestName, 'Connect');
    });

    test('ImportSshConfig answers the fleet, then the counts', () async {
      final client = await spawnEngine();
      final (:events, fleet: _) = await started(client);

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
      // The fields links need: the route, the sign-in and the filter text.
      expect(byLabel['bastion']!.jumpRoute, ['jump.example']);
      expect(byLabel['web-1']!.authKind, FleetAuthKind.identityFile);
      expect(byLabel['web-1']!.searchText, contains('web-1.example.com:2222'));
      expect(await events.moveNext(), isTrue);
      final answer = events.current as SshConfigImported;
      expect(answer.importedCount, sshConfigFixtureEntries.length);
      expect(answer.skippedCount, sshConfigFixtureSkipped);
      expect(answer.saved, isTrue);

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
    });

    test('send after shutdown throws; shutdown is idempotent', () async {
      final client = await spawnEngine();
      await client.shutdown();
      await client.shutdown();

      expect(() => client.send(const Connect('srv-1')), throwsStateError);
    });

    test('events close when the engine exits', () async {
      final client = await spawnEngine();
      // The startup fleet, then nothing: the handshake answer is spawn's.
      final done = expectLater(
        client.events.toList(),
        completion([isA<CatalogReplaced>()]),
      );
      await client.shutdown();
      await done;
    });
  });

  group('the import store (03 §4.10)', () {
    test('a restarted engine starts with the imports the last one '
        'saved', () async {
      final first = await spawnEngine();
      final (events: firstEvents, fleet: _) = await started(first);
      first.send(const ImportSshConfig(sshConfigFixture));
      final imported = (await next(firstEvents)) as CatalogReplaced;
      expect(((await next(firstEvents)) as SshConfigImported).saved, isTrue);
      await firstEvents.cancel();
      await first.shutdown();

      // Saved before the answer: the file holds the import in file order.
      final saved = jsonDecode(importsFile.readAsStringSync()) as Map;
      expect([
        for (final entry in saved['entries'] as List) (entry as Map)['alias'],
      ], sshConfigFixtureEntries);

      final second = await spawnEngine();
      expect(second.ready.importStoreIssue, isNull);
      final (events: secondEvents, :fleet) = await started(second);
      expect(fleet.entries, imported.entries, reason: 'by value');

      // A later import replaces the stored set, an empty one too.
      second.send(const ImportSshConfig('Host only\n  HostName 192.0.2.7\n'));
      await next(secondEvents);
      await next(secondEvents);
      await secondEvents.cancel();
      await second.shutdown();
      final third = await spawnEngine();
      final (events: thirdEvents, fleet: thirdFleet) = await started(third);
      expect(thirdFleet.entries.map((e) => e.serverId), ['ssh-config:only']);

      third.send(const ImportSshConfig('Host *\n  User nobody\n'));
      await next(thirdEvents);
      expect(((await next(thirdEvents)) as SshConfigImported).saved, isTrue);
      await thirdEvents.cancel();
      await third.shutdown();
      final (events: _, fleet: emptied) = await started(await spawnEngine());
      expect(emptied.entries, isEmpty);
    });

    test('hop records reach the fleet and survive a restart', () async {
      // a reaches gw.corp through the `*.corp` hop record, on 2222, where
      // b is behind another hop, so each entry names the other.
      const config =
          'Host *.corp\n  Port 2222\n'
          'Host a\n  HostName 10.0.0.5\n  ProxyJump gw.corp\n'
          'Host b\n  HostName gw.corp\n  Port 2222\n  ProxyJump other\n';
      Map<String, List<String>?> conflicts(CatalogReplaced fleet) => {
        for (final entry in fleet.entries) entry.label: entry.locatorConflict,
      };
      const expected = {
        'a': ['ssh-config:b'],
        'b': ['ssh-config:a'],
      };

      final first = await spawnEngine();
      final (events: firstEvents, fleet: _) = await started(first);
      first.send(const ImportSshConfig(config));
      expect(conflicts((await next(firstEvents)) as CatalogReplaced), expected);
      expect(((await next(firstEvents)) as SshConfigImported).saved, isTrue);
      await firstEvents.cancel();
      await first.shutdown();

      final (events: _, :fleet) = await started(await spawnEngine());
      expect(conflicts(fleet), expected);
    });

    test('a damaged store is reported at start and kept aside', () async {
      const damaged = '{"version": 1, "entries": [{"alias": "web-1"';
      importsFile.writeAsStringSync(damaged);

      final client = await spawnEngine();

      final issue = client.ready.importStoreIssue!;
      expect(issue.kind, ImportStoreIssueKind.recovered);
      expect(issue.preservedAs, startsWith('${importsFile.path}.corrupt-'));
      expect(File(issue.preservedAs!).readAsStringSync(), damaged);
      final (:events, :fleet) = await started(client);
      expect(fleet.entries, isEmpty);

      // The freed path takes the next import, and the next start is clean.
      client.send(const ImportSshConfig('Host web-1\n'));
      await next(events);
      expect(((await next(events)) as SshConfigImported).saved, isTrue);
      await events.cancel();
      await client.shutdown();

      final restarted = await spawnEngine();
      expect(restarted.ready.importStoreIssue, isNull);
      final (events: _, fleet: restored) = await started(restarted);
      expect(restored.entries.map((e) => e.label), ['web-1']);
      expect(File(issue.preservedAs!).readAsStringSync(), damaged);
    });

    test('a schema 1 store lists its hosts with neither route nor sign-in '
        'until the next import', () async {
      // What M1 saved for `Host db / HostName 10.0.0.5 / ProxyJump bastion
      // / IdentityFile ~/.ssh/k`: neither of the last two was kept.
      importsFile.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'entries': [
            {'alias': 'db', 'host': '10.0.0.5', 'port': 22},
          ],
        }),
      );

      final client = await spawnEngine();

      expect(client.ready.importStoreIssue, isNull);
      final (:events, :fleet) = await started(client);
      final stored = fleet.entries.single;
      expect((stored.label, stored.host), ('db', '10.0.0.5'));
      expect(stored.jumpRoute, isNull);
      expect(stored.authKind, isNull, reason: 'unknown, not the agent');

      client.send(
        const ImportSshConfig(
          'Host db\n  HostName 10.0.0.5\n  ProxyJump bastion\n'
          '  IdentityFile ~/.ssh/k\n',
        ),
      );
      final imported = ((await next(events)) as CatalogReplaced).entries.single;
      expect(imported.jumpRoute, ['bastion']);
      expect(imported.authKind, FleetAuthKind.identityFile);
    });

    test('an import that cannot be saved shows for this run and says '
        'so', () async {
      // Missing at start, so the store opens empty; a file in the
      // directory's place then makes the save fail.
      final directory = '${support.path}/support';
      final client = await spawnEngine(directory: directory);
      final (:events, fleet: _) = await started(client);
      File(directory).writeAsStringSync('in the way');

      client.send(const ImportSshConfig('Host web-1\n'));
      final fleet = (await next(events)) as CatalogReplaced;
      expect(fleet.entries.map((e) => e.label), ['web-1']);
      final answer = (await next(events)) as SshConfigImported;
      expect(answer.importedCount, 1);
      expect(answer.saved, isFalse);
      await events.cancel();
      await client.shutdown();

      File(directory).deleteSync();
      final (events: _, fleet: restarted) = await started(
        await spawnEngine(directory: directory),
      );
      expect(restarted.entries, isEmpty);
    });

    test('a store the engine leaves as it is saves no import', () async {
      // A file a newer build wrote. Unlike an unreadable one, it would
      // take a save, so its unchanged bytes show the engine never tried.
      final newer = jsonEncode({
        'version': sshConfigImportsSchemaVersion + 1,
        'entries': <Object?>[],
      });
      importsFile.writeAsStringSync(newer);

      final client = await spawnEngine();

      expect(
        client.ready.importStoreIssue?.kind,
        ImportStoreIssueKind.newerVersion,
      );
      final (:events, fleet: _) = await started(client);
      client.send(const ImportSshConfig('Host web-1\n'));
      expect(((await next(events)) as CatalogReplaced).entries, hasLength(1));
      expect(((await next(events)) as SshConfigImported).saved, isFalse);
      expect(importsFile.readAsStringSync(), newer);
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
      final isolate = await Isolate.spawn(
        engineMain,
        EngineStart(uiPort: port.sendPort, supportDirectory: support.path),
      );
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
        IsolateEngineClient.spawn(
          supportDirectory: support.path,
          entryPoint: _exitAtOnce,
        ),
        throwsStateError,
      );
    });

    test('spawn fails when the engine refuses Hello', () async {
      await expectLater(
        IsolateEngineClient.spawn(
          supportDirectory: support.path,
          entryPoint: _refuseHello,
        ),
        throwsStateError,
      );
    });
  });
}

/// An engine that dies before it hands over its command port.
void _exitAtOnce(EngineStart start) => Isolate.exit();

/// An engine that answers the handshake with a refusal.
void _refuseHello(EngineStart start) {
  final commands = ReceivePort();
  start.uiPort.send(commands.sendPort);
  commands.listen(
    (_) => start.uiPort.send(const RequestRejected('Hello', 'no')),
  );
}
