import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/services/ssh_config_source.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/fake_ssh_config.dart';

FleetEntry _entry(
  String alias, {
  String? host,
  int port = kSshDefaultPort,
  String? user,
}) {
  return FleetEntry(
    serverId: 'ssh-config:$alias',
    label: alias,
    host: host ?? alias,
    port: port,
    user: user,
    origin: FleetEntryOrigin.sshConfig,
  );
}

const _config = 'Host web-1\n  HostName web-1.example\n';

void main() {
  late FakeEngineClient engine;

  setUp(() => engine = FakeEngineClient());
  tearDown(() => engine.close());

  FleetController controller({
    List<FleetServer> servers = const [],
    SshConfigSource? sshConfig,
  }) {
    final fleet = FleetController(
      engine,
      servers: servers,
      sshConfig: sshConfig,
    );
    addTearDown(fleet.dispose);
    return fleet;
  }

  /// Lets the fake engine's broadcast events and the read reach the
  /// controller.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('CatalogReplaced (03 §10.1)', () {
    test('replaces the list in order and notifies', () async {
      final fleet = controller(
        servers: const [FleetServer(id: 'seed', displayName: 'seed')],
      );
      var notified = 0;
      fleet.addListener(() => notified++);

      engine.emit(
        CatalogReplaced([
          _entry('web-1', host: 'web-1.example', user: 'deploy'),
          _entry('db-1', host: 'db.example', port: 2222),
        ]),
      );
      await settle();

      expect(fleet.servers.map((s) => s.id), [
        'ssh-config:web-1',
        'ssh-config:db-1',
      ]);
      expect(fleet.servers.map((s) => s.displayName), ['web-1', 'db-1']);
      expect(notified, 1);
    });

    test('row addresses leave out port 22 and bracket IPv6 hosts', () {
      String? address(FleetEntry entry) => FleetServer.fromEntry(entry).address;

      expect(address(_entry('a', host: 'a.example')), 'a.example');
      expect(
        address(_entry('a', host: 'a.example', user: 'me')),
        'me@a.example',
      );
      expect(
        address(_entry('a', host: 'a.example', port: 2222)),
        'a.example:2222',
      );
      expect(
        address(_entry('a', host: '2001:db8::1', port: 2200, user: 'root')),
        'root@[2001:db8::1]:2200',
      );
      expect(address(_entry('a', host: '2001:db8::1')), '2001:db8::1');
    });

    test('rows carry the engine\'s search text and locator flag', () {
      const entry = FleetEntry(
        serverId: 'ssh-config:web-1',
        label: 'web-1',
        host: '10.0.0.4',
        port: kSshDefaultPort,
        origin: FleetEntryOrigin.sshConfig,
        searchText: 'web-1 deploy@10.0.0.4:22 ',
        locatorConflict: ['ssh-config:db-1'],
      );
      final server = FleetServer.fromEntry(entry);

      expect(server.searchText, 'web-1 deploy@10.0.0.4:22 ');
      expect(server.locatorConflict, ['ssh-config:db-1']);
      expect(FleetServer.fromEntry(_entry('a')).locatorConflict, isNull);
    });

    test('rows carry where the entry came from and its group (FL-06)', () {
      const synced = FleetEntry(
        serverId: 'srv-1',
        label: 'web-1',
        host: 'web-1.example',
        port: kSshDefaultPort,
        origin: FleetEntryOrigin.synced,
        group: 'Production',
      );

      final server = FleetServer.fromEntry(synced);
      expect(server.origin, FleetEntryOrigin.synced);
      expect(server.group, 'Production');
      final import = FleetServer.fromEntry(_entry('a'));
      expect(import.origin, FleetEntryOrigin.sshConfig);
      expect(import.group, isNull);
    });

    test(
      'keeps a selection the new fleet lists and drops one it does not',
      () async {
        final fleet = controller();
        engine.emit(CatalogReplaced([_entry('web-1'), _entry('db-1')]));
        await settle();
        fleet.select('ssh-config:db-1');

        engine.emit(CatalogReplaced([_entry('db-1')]));
        await settle();
        expect(fleet.selectedServerId, 'ssh-config:db-1');

        engine.emit(CatalogReplaced([_entry('web-1')]));
        await settle();
        expect(fleet.selectedServerId, isNull);
        expect(fleet.selectedServer, isNull);
      },
    );

    test('forgets the link status and reachability of a server the new '
        'fleet drops', () async {
      const failed = LinkClosed(
        LinkClosedReason.connectFailed,
        failure: LinkFailureKind.unreachable,
      );
      final fleet = controller();
      engine
        ..emit(CatalogReplaced([_entry('web-1'), _entry('db-1')]))
        ..emit(const LinkState('ssh-config:web-1', LinkReady()))
        ..emit(
          const Reachability('ssh-config:web-1', ReachabilityStatus.online),
        )
        ..emit(const LinkState('ssh-config:db-1', failed));
      await settle();

      engine.emit(CatalogReplaced([_entry('db-1')]));
      await settle();
      expect(fleet.linkStatusFor('ssh-config:db-1'), failed);

      // A re-added server starts idle and unprobed, not as it was.
      engine.emit(CatalogReplaced([_entry('web-1'), _entry('db-1')]));
      await settle();
      expect(fleet.linkStatusFor('ssh-config:web-1'), const LinkIdle());
      expect(fleet.reachabilityFor('ssh-config:web-1'), isNull);
    });
  });

  group('LinkState and Reachability (03 §10.1, D46)', () {
    test('keep the last value per server and notify once per change', () async {
      final fleet = controller();
      engine.emit(CatalogReplaced([_entry('web-1')]));
      await settle();
      var notified = 0;
      fleet.addListener(() => notified++);

      expect(fleet.linkStatusFor('ssh-config:web-1'), const LinkIdle());
      expect(fleet.reachabilityFor('ssh-config:web-1'), isNull);

      final until = DateTime.utc(2026, 10, 14, 12);
      engine
        ..emit(LinkState('ssh-config:web-1', LinkBackoff(until)))
        // Each event is a new copy; an equal one is no change.
        ..emit(
          LinkState(
            'ssh-config:web-1',
            LinkBackoff(DateTime.utc(2026, 10, 14, 12)),
          ),
        )
        ..emit(
          const Reachability('ssh-config:web-1', ReachabilityStatus.unknown),
        )
        ..emit(
          const Reachability('ssh-config:web-1', ReachabilityStatus.unknown),
        );
      await settle();

      expect(fleet.linkStatusFor('ssh-config:web-1'), LinkBackoff(until));
      expect(
        fleet.reachabilityFor('ssh-config:web-1'),
        ReachabilityStatus.unknown,
      );
      expect(notified, 2);
    });

    test('ignore servers the fleet does not list', () async {
      final fleet = controller();
      engine.emit(CatalogReplaced([_entry('web-1')]));
      await settle();
      var notified = 0;
      fleet.addListener(() => notified++);

      engine
        ..emit(const LinkState('ssh-config:db-1', LinkReady()))
        ..emit(
          const Reachability('ssh-config:db-1', ReachabilityStatus.online),
        );
      await settle();
      expect(notified, 0);

      // Listed later, the server starts idle and unprobed: nothing that
      // arrived before it was in the fleet resurfaces.
      engine.emit(CatalogReplaced([_entry('web-1'), _entry('db-1')]));
      await settle();
      expect(fleet.linkStatusFor('ssh-config:db-1'), const LinkIdle());
      expect(fleet.reachabilityFor('ssh-config:db-1'), isNull);
    });

    test('count the seeded servers as the fleet', () async {
      final fleet = controller(
        servers: const [FleetServer(id: 'seed', displayName: 'seed')],
      );

      engine
        ..emit(const LinkState('seed', LinkConnecting()))
        ..emit(const LinkState('other', LinkConnecting()));
      await settle();

      expect(fleet.linkStatusFor('seed'), const LinkConnecting());
      expect(fleet.linkStatusFor('other'), const LinkIdle());
    });
  });

  group('pins (03 §10.3)', () {
    test('start from the restored set, apply at once and save', () async {
      final saved = <Set<String>>[];
      final fleet = FleetController(
        engine,
        pinnedServerIds: {'srv-1'},
        savePins: (ids) async => saved.add(ids),
      );
      addTearDown(fleet.dispose);
      var notified = 0;
      fleet.addListener(() => notified++);

      expect(fleet.pinnedServerIds, {'srv-1'});
      await fleet.pin('srv-2');
      expect(fleet.pinnedServerIds, {'srv-1', 'srv-2'});
      await fleet.unpin('srv-1');
      expect(fleet.pinnedServerIds, {'srv-2'});

      expect(saved, [
        {'srv-1', 'srv-2'},
        {'srv-2'},
      ]);
      expect(notified, 2);
      expect(
        () => fleet.pinnedServerIds.add('srv-3'),
        throwsUnsupportedError,
        reason: 'changes go through pin and unpin',
      );
    });

    test('a change that changes nothing saves nothing', () async {
      var saves = 0;
      final fleet = FleetController(
        engine,
        pinnedServerIds: {'srv-1'},
        savePins: (_) async => saves++,
      );
      addTearDown(fleet.dispose);

      await fleet.pin('srv-1');
      await fleet.unpin('srv-2');

      expect(saves, 0);
    });

    test('a save that fails rethrows and keeps the change', () async {
      final fleet = FleetController(
        engine,
        savePins: (_) async => throw const FileSystemException('disk full'),
      );
      addTearDown(fleet.dispose);

      await expectLater(
        fleet.pin('srv-1'),
        throwsA(isA<FileSystemException>()),
      );
      expect(fleet.pinnedServerIds, {'srv-1'});
    });

    test('outlast a sync that drops the server and brings it back', () async {
      final fleet = controller();
      await fleet.pin('srv-1');

      engine.emit(CatalogReplaced(const []));
      await settle();
      expect(fleet.pinnedServerIds, {'srv-1'});
    });
  });

  group('importSshConfig (FL-02)', () {
    test('is unavailable without a source', () {
      final fleet = controller();

      expect(fleet.canImportSshConfig, isFalse);
      expect(fleet.importSshConfig, throwsStateError);
      expect(engine.sent, isEmpty);
    });

    test('sends the text and completes on the engine\'s answer', () async {
      final fleet = controller(sshConfig: FakeSshConfigSource.text(_config));
      expect(fleet.canImportSshConfig, isTrue);

      final outcome = fleet.importSshConfig();
      expect(fleet.isImportingSshConfig, isTrue);
      await settle();

      final request = engine.sentOfType<ImportSshConfig>().single;
      expect((request as ImportSshConfig).text, _config);

      engine
        ..emit(CatalogReplaced([_entry('web-1', host: 'web-1.example')]))
        ..emit(
          const SshConfigImported(
            importedCount: 1,
            skippedCount: 3,
            saved: true,
          ),
        );

      final result = await outcome as SshConfigImportSucceeded;
      expect(result.importedCount, 1);
      expect(result.skippedCount, 3);
      expect(result.saved, isTrue);
      // The fleet already shows the import when the answer completes.
      expect(fleet.servers.single.address, 'web-1.example');
      expect(fleet.isImportingSshConfig, isFalse);
      // The only traffic: the import itself, never a catalog write (D14).
      expect(engine.sent, hasLength(1));
    });

    test('an import the engine could not save says so', () async {
      final fleet = controller(sshConfig: FakeSshConfigSource.text(_config));
      final outcome = fleet.importSshConfig();
      await settle();

      engine
        ..emit(CatalogReplaced([_entry('web-1')]))
        ..emit(
          const SshConfigImported(
            importedCount: 1,
            skippedCount: 0,
            saved: false,
          ),
        );

      final result = await outcome as SshConfigImportSucceeded;
      expect(result.saved, isFalse);
      expect(fleet.servers.single.id, 'ssh-config:web-1');
    });

    test('a second call while one runs joins it', () async {
      final source = FakeSshConfigSource.text(_config)..gate = Completer();
      final fleet = controller(sshConfig: source);

      final first = fleet.importSshConfig();
      final second = fleet.importSshConfig();
      expect(identical(first, second), isTrue);

      source.gate!.complete();
      await settle();
      engine.emit(
        const SshConfigImported(importedCount: 0, skippedCount: 0, saved: true),
      );
      await first;

      expect(source.reads, 1);
      expect(engine.sentOfType<ImportSshConfig>(), hasLength(1));
    });

    test('an unreadable config never reaches the engine', () async {
      for (final failure in SshConfigReadFailure.values) {
        final fleet = controller(
          sshConfig: FakeSshConfigSource.failing(failure),
        );

        final outcome = await fleet.importSshConfig();

        expect((outcome as SshConfigImportUnreadable).failure, failure);
        expect(fleet.isImportingSshConfig, isFalse);
      }
      expect(engine.sent, isEmpty);
    });

    test('an engine rejection of the import ends it; others do not', () async {
      final fleet = controller(sshConfig: FakeSshConfigSource.text(_config));
      var done = false;
      final outcome = fleet.importSshConfig().whenComplete(() => done = true);
      await settle();

      engine.emit(const RequestRejected('Connect', 'not implemented yet'));
      await settle();
      expect(done, isFalse);

      engine.emit(const RequestRejected('ImportSshConfig', 'boom'));
      final result = await outcome;
      expect((result as SshConfigImportRejected).reason, 'boom');
    });

    test('an engine that stops mid-import ends it as rejected', () async {
      final fleet = controller(sshConfig: FakeSshConfigSource.text(_config));
      final outcome = fleet.importSshConfig();
      await settle();

      await engine.close();

      expect(await outcome, isA<SshConfigImportRejected>());
      expect(fleet.isImportingSshConfig, isFalse);
    });
  });

  test('imports through the real engine isolate (CN-19), and a restart '
      'restores them (03 §4.10)', () async {
    final support = Directory.systemTemp.createTempSync('klab-fleet-');
    addTearDown(() => support.deleteSync(recursive: true));
    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
    );
    addTearDown(client.shutdown);
    final fleet = FleetController(
      client,
      sshConfig: FakeSshConfigSource.text(
        '# The engine isolate parses this, not the UI isolate. As in\n'
        '# ssh, the first value wins: Host * gives only db-1 a User.\n'
        'Host web-1\n  HostName web-1.example\n  User deploy\n'
        'Host db-1\n  HostName 10.0.0.4\n  Port 2222\n'
        'Host bad\n  Port 99999\n'
        'Host *\n  User everyone\n',
      ),
    );
    addTearDown(fleet.dispose);

    final outcome = await fleet.importSshConfig() as SshConfigImportSucceeded;

    expect(outcome.importedCount, 2);
    expect(outcome.skippedCount, 1);
    expect(outcome.saved, isTrue);
    const imported = [
      ('web-1', 'deploy@web-1.example'),
      ('db-1', 'everyone@10.0.0.4:2222'),
    ];
    expect(fleet.servers.map((s) => (s.displayName, s.address)), imported);

    // The next launch: a new engine over the same support directory, and
    // a controller built a moment after spawn, as the composition root
    // may. The startup fleet still reaches it.
    await client.shutdown();
    final restarted = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
    );
    addTearDown(restarted.shutdown);
    expect(restarted.ready.importStoreIssue, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final next = FleetController(restarted);
    addTearDown(next.dispose);
    final restored = Completer<void>();
    next.addListener(() {
      if (!restored.isCompleted) restored.complete();
    });

    await restored.future.timeout(const Duration(seconds: 5));
    expect(next.servers.map((s) => (s.displayName, s.address)), imported);
  });
}
