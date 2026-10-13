import 'dart:async';

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
        ..emit(const SshConfigImported(importedCount: 1, skippedCount: 3));

      final result = await outcome as SshConfigImportSucceeded;
      expect(result.importedCount, 1);
      expect(result.skippedCount, 3);
      // The fleet already shows the import when the answer completes.
      expect(fleet.servers.single.address, 'web-1.example');
      expect(fleet.isImportingSshConfig, isFalse);
      // The only traffic: the import itself, never a catalog write (D14).
      expect(engine.sent, hasLength(1));
    });

    test('a second call while one runs joins it', () async {
      final source = FakeSshConfigSource.text(_config)..gate = Completer();
      final fleet = controller(sshConfig: source);

      final first = fleet.importSshConfig();
      final second = fleet.importSshConfig();
      expect(identical(first, second), isTrue);

      source.gate!.complete();
      await settle();
      engine.emit(const SshConfigImported(importedCount: 0, skippedCount: 0));
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

  test('imports through the real engine isolate (CN-19)', () async {
    final client = await IsolateEngineClient.spawn();
    addTearDown(client.shutdown);
    final fleet = FleetController(
      client,
      sshConfig: FakeSshConfigSource.text(
        '# The engine isolate parses this, not the UI isolate.\n'
        'Host *\n  User everyone\n'
        'Host web-1\n  HostName web-1.example\n  User deploy\n'
        'Host db-1\n  HostName 10.0.0.4\n  Port 2222\n'
        'Host bad\n  Port 99999\n',
      ),
    );
    addTearDown(fleet.dispose);

    final outcome = await fleet.importSshConfig() as SshConfigImportSucceeded;

    expect(outcome.importedCount, 2);
    expect(outcome.skippedCount, 1);
    expect(fleet.servers.map((s) => (s.displayName, s.address)), [
      ('web-1', 'deploy@web-1.example'),
      ('db-1', '10.0.0.4:2222'),
    ]);
  });
}
