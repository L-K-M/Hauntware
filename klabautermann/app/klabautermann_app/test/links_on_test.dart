import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_ssh_config.dart';

const _web = 'ssh-config:web';

/// The real engine isolate as `main.dart` spawns it: links on, which
/// architecture_contract_test holds there, so opening a server's view
/// connects it. The fake engine the widget tests use cannot show this.
void main() {
  late Directory support;

  setUp(() => support = Directory.systemTemp.createTempSync('klab-links-'));
  tearDown(() => support.deleteSync(recursive: true));

  Future<IsolateEngineClient> spawn() async {
    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
      linksEnabled: true,
      supportDirectoryAccess: SupportDirectoryAccess.exclusive,
    );
    addTearDown(client.shutdown);
    return client;
  }

  /// Completes once [listenable] notifies with [done] true.
  Future<void> until(Listenable listenable, bool Function() done) {
    if (done()) return Future.value();
    final reached = Completer<void>();
    void check() {
      if (done() && !reached.isCompleted) reached.complete();
    }

    listenable.addListener(check);
    return reached.future
        .timeout(const Duration(seconds: 10))
        .whenComplete(() => listenable.removeListener(check));
  }

  test('opening an imported server starts a connect', () async {
    // A loopback port nothing listens on, so the dial ends at once.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();

    final engine = await spawn();
    final fleet = FleetController(
      engine,
      sshConfig: FakeSshConfigSource.text(
        'Host web\n  HostName 127.0.0.1\n  Port $port\n  User me\n',
      ),
    );
    addTearDown(fleet.dispose);
    final monitoring = MonitoringController(engine);
    addTearDown(monitoring.dispose);
    await fleet.importSshConfig();
    expect(fleet.linkStatusFor(_web), isA<LinkIdle>());

    monitoring.openServer(_web);

    await until(fleet, () => fleet.linkStatusFor(_web) is! LinkIdle);
    expect(fleet.linkStatusFor(_web), isA<LinkConnecting>());
    expect(monitoring.connectRejections.value, isEmpty);
  });

  test('a server without a config gets the rejection its views show', () async {
    // A schema 1 store kept addresses only, so the engine has no config
    // for its hosts until the next import (03 §4.10).
    File(
      '${support.path}${Platform.pathSeparator}ssh_config_imports.json',
    ).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'entries': [
          {'alias': 'web', 'host': '192.0.2.10', 'port': 22, 'user': 'me'},
        ],
      }),
    );
    final engine = await spawn();
    final fleet = FleetController(engine);
    addTearDown(fleet.dispose);
    final monitoring = MonitoringController(engine);
    addTearDown(monitoring.dispose);
    await until(fleet, () => fleet.servers.any((s) => s.id == _web));

    monitoring.openServer(_web);

    await until(
      monitoring.connectRejections,
      () => monitoring.connectRejections.value.isNotEmpty,
    );
    expect(monitoring.connectRejections.value, {
      _web: ConnectRejectedReason.addressOnlyImport,
    });
    expect(fleet.linkStatusFor(_web), isA<LinkIdle>());
  });
}
