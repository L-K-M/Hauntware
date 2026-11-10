// FL-16's admin memory (03 §8.2, D69): a per-server switch, off by
// default and kept on this device only, that turns admin mode back on at
// the server's first user-visible connect of a launch. The engine still
// asks for the password, and admin mode still ends as it does when the
// user turns it on; nothing re-arms it within the launch.
import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/admin_memory.dart';
import 'package:ghost_keystore/app_lock.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/settings_page.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

const _server = 'srv-1';

const _managed = SafetyPolicy(
  servers: {_server: ServerSafety(management: true)},
);

/// An app lock the test locks and unlocks by hand.
final class _ManualAppLock extends ChangeNotifier implements AppLockSettings {
  _ManualAppLock({this._locked = false});

  @override
  bool get enabled => true;

  @override
  AppLockSupport get support => AppLockSupport.available;

  @override
  bool get locked => _locked;
  bool _locked;
  set locked(bool locked) {
    _locked = locked;
    notifyListeners();
  }

  @override
  Future<AppLockChange> setEnabled(bool enabled) async => AppLockChange.changed;
}

/// One launch: the controllers `main.dart` composes for admin memory,
/// over a fake engine.
final class _Launch {
  _Launch._({
    required this.engine,
    required this.monitoring,
    required this.admin,
    required this.memory,
    required this.safety,
    required this.appLock,
    required this.rearm,
  });

  factory _Launch({
    required Set<String> remembered,
    required SafetyPolicy policy,
    _ManualAppLock? appLock,
  }) {
    final engine = FakeEngineClient();
    final monitoring = MonitoringController(engine, linkGrace: Duration.zero);
    final admin = AdminController(engine);
    final memory = AdminMemoryController(remembered: remembered);
    final safety = SafetyController(initial: policy, apply: (_) {});
    return _Launch._(
      engine: engine,
      monitoring: monitoring,
      admin: admin,
      memory: memory,
      safety: safety,
      appLock: appLock,
      rearm: AdminRearm(
        engine: engine,
        admin: admin,
        remembered: memory,
        visibleServers: monitoring.visibleServers,
        safety: safety,
        appLock: appLock,
      ),
    );
  }

  final FakeEngineClient engine;
  final MonitoringController monitoring;
  final AdminController admin;
  final AdminMemoryController memory;
  final SafetyController safety;
  final _ManualAppLock? appLock;
  final AdminRearm rearm;

  /// What the app asked of admin mode, in order.
  List<(String, bool)> get adminRequests => [
    for (final request
        in engine.sentOfType<SetAdminMode>().cast<SetAdminMode>())
      (request.serverId, request.enabled),
  ];

  Future<void> emit(EngineEvent event) async {
    engine.emit(event);
    await pumpEventQueue();
  }

  /// The link comes up and its probe answers, as after a connect.
  Future<void> connected({String serverId = _server}) async {
    await emit(LinkState(serverId, const LinkReady()));
    await emit(HostProfileChanged(serverId, HostProfile()));
  }

  Future<void> linkLost({String serverId = _server}) =>
      emit(LinkState(serverId, const LinkConnecting()));

  Future<void> dispose() async {
    rearm.dispose();
    admin.dispose();
    monitoring.dispose();
    safety.dispose();
    memory.dispose();
    appLock?.dispose();
    await engine.close();
  }
}

Future<_Launch> _launch({
  Set<String> remembered = const {_server},
  SafetyPolicy policy = _managed,
  _ManualAppLock? appLock,
}) async {
  final launch = _Launch(
    remembered: remembered,
    policy: policy,
    appLock: appLock,
  );
  addTearDown(launch.dispose);
  await pumpEventQueue();
  return launch;
}

void main() {
  group('AdminMemoryController', () {
    test('is off for every server by default', () {
      final memory = AdminMemoryController();
      addTearDown(memory.dispose);

      expect(memory.value, isEmpty);
    });

    test(
      'saves each change as the whole set, and a repeat saves nothing',
      () async {
        final saved = <Set<String>>[];
        final memory = AdminMemoryController(
          remembered: {'srv-2'},
          save: (ids) async => saved.add(ids),
        );
        addTearDown(memory.dispose);

        await memory.setRemembered(_server, remembered: true);
        await memory.setRemembered(_server, remembered: true);
        await memory.setRemembered('srv-2', remembered: false);

        expect(saved, [
          {'srv-2', _server},
          {_server},
        ]);
        expect(memory.value, {_server});
      },
    );

    test('a change that applied but was not saved throws and stays in '
        'force', () async {
      final memory = AdminMemoryController(
        save: (_) async => throw const FileSystemException('disk full'),
      );
      addTearDown(memory.dispose);

      await expectLater(
        memory.setRemembered(_server, remembered: true),
        throwsA(isA<AdminMemoryNotSavedException>()),
      );
      expect(memory.value, {_server});
    });
  });

  group('AdminRearm', () {
    test('with the switch on, the first user-visible connect of the launch '
        'turns admin mode on, once', () async {
      final launch = await _launch();

      launch.monitoring.openServer(_server);
      await pumpEventQueue();
      expect(launch.engine.sentOfType<Connect>(), hasLength(1));
      expect(launch.adminRequests, isEmpty);

      await launch.connected();
      expect(launch.adminRequests, [(_server, true)]);

      // The engine runs admin mode as for the header's chip: it asks for
      // the password, and nothing here answers it.
      await launch.emit(
        const AdminModeState(_server, AdminModePhase.awaitingPassword),
      );
      await launch.connected();
      expect(launch.adminRequests, [(_server, true)]);
    });

    test('with the switch off, a connect leaves the server observe-only '
        '(SAF-01)', () async {
      final launch = await _launch(remembered: const {});

      launch.monitoring.openServer(_server);
      await launch.connected();

      expect(launch.adminRequests, isEmpty);
      expect(launch.admin.stateFor(_server), isNull);
    });

    test('a cached profile, or a link the monitor set dialed unattended, '
        'decides nothing until the user opens the server', () async {
      final launch = await _launch();

      // The device cache's profile from an earlier run (D59).
      await launch.emit(
        HostProfileChanged(_server, HostProfile(), cachedAt: DateTime(2026)),
      );
      // An unattended link with no view open.
      await launch.connected();
      expect(launch.adminRequests, isEmpty);

      launch.monitoring.openServer(_server);
      await pumpEventQueue();
      expect(launch.adminRequests, [(_server, true)]);
    });

    test('waits for the probe of a link that came back', () async {
      final launch = await _launch();
      await launch.connected();
      await launch.linkLost();

      launch.monitoring.openServer(_server);
      await pumpEventQueue();
      await launch.emit(const LinkState(_server, LinkReady()));
      expect(launch.adminRequests, isEmpty);

      await launch.emit(HostProfileChanged(_server, HostProfile()));
      expect(launch.adminRequests, [(_server, true)]);
    });

    test('a cancelled prompt leaves the server observe-only and is not '
        'asked again this launch', () async {
      final launch = await _launch();
      launch.monitoring.openServer(_server);
      await launch.connected();
      await launch.emit(
        const AdminModeState(
          _server,
          AdminModePhase.failed,
          failure: AdminFailure.cancelled,
        ),
      );

      // A reconnect and a new view connect again; neither asks.
      await launch.linkLost();
      await launch.connected();
      launch.monitoring.leaveServer(_server);
      launch.monitoring.openServer(_server);
      await launch.connected();

      expect(launch.adminRequests, [(_server, true)]);
    });

    for (final end in AdminEnd.values) {
      test('admin mode ended by ${end.name} is not turned on again this '
          'launch', () async {
        final launch = await _launch();
        launch.monitoring.openServer(_server);
        await launch.connected();
        await launch.emit(
          AdminModeState(
            _server,
            AdminModePhase.on,
            expiresAt: DateTime.now().add(const Duration(minutes: 15)),
          ),
        );
        await launch.emit(
          AdminModeState(_server, AdminModePhase.expired, ended: end),
        );

        launch.monitoring.setAppActivity(AppActivity.background);
        launch.monitoring.setAppActivity(AppActivity.foreground);
        await launch.linkLost();
        await launch.connected();

        expect(launch.adminRequests, [(_server, true)]);
      });
    }

    for (final (name, policy) in [
      ('observe-only', const SafetyPolicy()),
      (
        'read-only',
        const SafetyPolicy(
          servers: {_server: ServerSafety(management: true, readOnly: true)},
        ),
      ),
      (
        'under global read-only',
        const SafetyPolicy(
          globalReadOnly: true,
          servers: {_server: ServerSafety(management: true)},
        ),
      ),
    ]) {
      test('a remembered server that is $name stays silent', () async {
        final launch = await _launch(policy: policy);

        launch.monitoring.openServer(_server);
        await launch.connected();

        expect(launch.adminRequests, isEmpty);
      });
    }

    test('in the background nothing is decided; the return decides', () async {
      final launch = await _launch();
      launch.monitoring.openServer(_server);
      launch.monitoring.setAppActivity(AppActivity.background);
      await launch.connected();
      expect(launch.adminRequests, isEmpty);

      launch.monitoring.setAppActivity(AppActivity.foreground);
      await pumpEventQueue();
      expect(launch.adminRequests, [(_server, true)]);
    });

    test('a locked app decides once it is unlocked (SAF-20)', () async {
      final lock = _ManualAppLock(locked: true);
      final launch = await _launch(appLock: lock);
      launch.monitoring.openServer(_server);
      await launch.connected();
      expect(launch.adminRequests, isEmpty);

      lock.locked = false;
      await pumpEventQueue();
      expect(launch.adminRequests, [(_server, true)]);
    });

    test(
      'admin mode the user asked for first is not asked for again',
      () async {
        final launch = await _launch();
        launch.monitoring.openServer(_server);
        await pumpEventQueue();
        launch.admin.setEnabled(_server, enabled: true);
        await launch.emit(
          const AdminModeState(_server, AdminModePhase.detecting),
        );

        await launch.connected();

        expect(launch.adminRequests, [(_server, true)]);
      },
    );

    test('a switch turned on after the connect applies from the next '
        'launch', () async {
      final launch = await _launch(remembered: const {});
      launch.monitoring.openServer(_server);
      await launch.connected();

      await launch.memory.setRemembered(_server, remembered: true);
      await launch.linkLost();
      await launch.connected();

      expect(launch.adminRequests, isEmpty);
    });

    test('decides each server on its own', () async {
      final launch = await _launch(
        remembered: const {_server, 'srv-2'},
        policy: const SafetyPolicy(
          servers: {
            _server: ServerSafety(management: true),
            'srv-2': ServerSafety(management: true),
          },
        ),
      );
      launch.monitoring.openServer(_server);
      await launch.connected();
      launch.monitoring.openServer('srv-2');
      await launch.connected(serverId: 'srv-2');

      expect(launch.adminRequests, [(_server, true), ('srv-2', true)]);
    });
  });

  group('device-local (D69)', () {
    test('a synced pref record cannot turn it on', () async {
      final launch = await _launch(remembered: const {});

      await launch.emit(
        const ServerPrefsChanged(_server, ServerPrefs(readOnly: false)),
      );
      launch.monitoring.openServer(_server);
      await launch.connected();

      expect(launch.memory.value, isEmpty);
      expect(launch.adminRequests, isEmpty);
    });
  });

  group('Settings > Servers', () {
    Future<(FakeEngineClient, AdminMemoryController)> pumpTab(
      WidgetTester tester, {
      Future<void> Function(Set<String> ids)? save,
    }) async {
      final engine = FakeEngineClient();
      final fleet = FleetController(engine, servers: twoServers);
      final memory = AdminMemoryController(save: save);
      addTearDown(() async {
        memory.dispose();
        fleet.dispose();
        await engine.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ServersTab(
              monitorSet: fleet.monitorSettings,
              adminMemory: memory,
            ),
          ),
        ),
      );
      return (engine, memory);
    }

    Finder rememberSwitch(String server) =>
        find.bySemanticsLabel('Remember admin mode on $server');

    testWidgets('each server has a switch, off by default, whose copy says '
        'it asks for the password at each launch and allows changes', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final (engine, memory) = await pumpTab(tester);
      final sentBefore = engine.sent.length;

      expect(find.text('Remember admin mode'), findsOneWidget);
      expect(
        find.textContaining(
          'It asks for the sudo password at each launch and never saves it.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Admin mode lets you make changes on that server as root.',
        ),
        findsOneWidget,
      );
      expect(rememberSwitch('web-1'), findsOneWidget);
      expect(rememberSwitch('db-1'), findsOneWidget);
      final switches = tester.widgetList<SwitchListTile>(
        find.ancestor(
          of: find.text('web-1'),
          matching: find.byType(SwitchListTile),
        ),
      );
      expect(switches.map((tile) => tile.value), everyElement(isFalse));

      // The admin memory section follows the monitor set's.
      await tester.ensureVisible(find.text('web-1').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('web-1').last);
      await tester.pumpAndSettle();

      expect(memory.value, {_server});
      expect(
        tester
            .widgetList<SwitchListTile>(
              find.ancestor(
                of: find.text('web-1'),
                matching: find.byType(SwitchListTile),
              ),
            )
            .map((tile) => tile.value),
        contains(isTrue),
      );
      // Nothing reaches the engine, so no pref record can carry it.
      expect(engine.sent.length, sentBefore);
      semantics.dispose();
    });

    testWidgets('says when the switch changed but could not be saved', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final (_, memory) = await pumpTab(
        tester,
        save: (_) async => throw const FileSystemException('disk full'),
      );

      // The admin memory section follows the monitor set's.
      await tester.ensureVisible(find.text('db-1').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('db-1').last);
      await tester.pumpAndSettle();

      expect(memory.value, {'srv-2'});
      expect(
        find.text(
          'The admin mode setting changed but could not be saved. It lasts '
          'until Klabautermann quits.',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      semantics.dispose();
    });

    testWidgets('without admin memory the tab leaves it out', (tester) async {
      final engine = FakeEngineClient();
      final fleet = FleetController(engine, servers: twoServers);
      addTearDown(() async {
        fleet.dispose();
        await engine.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ServersTab(monitorSet: fleet.monitorSettings)),
        ),
      );

      expect(find.text('Remember admin mode'), findsNothing);
    });
  });

  testWidgets('in the app, opening a remembered server after launch shows '
      'the password prompt; Cancel leaves it observe-only for the launch', (
    tester,
  ) async {
    final safety = SafetyController(initial: _managed, apply: (_) {});
    final memory = AdminMemoryController(remembered: {_server});
    final harness = await pumpApp(
      tester,
      servers: twoServers,
      safety: safety,
      admin: true,
    );
    final rearm = AdminRearm(
      engine: harness.engine,
      admin: harness.admin!,
      remembered: memory,
      visibleServers: harness.monitoring.visibleServers,
      safety: safety,
    );
    addTearDown(() {
      rearm.dispose();
      memory.dispose();
      safety.dispose();
    });
    Future<void> emit(EngineEvent event) async {
      harness.engine.emit(event);
      await tester.pumpAndSettle();
    }

    List<SetAdminMode> asked() =>
        harness.engine.sentOfType<SetAdminMode>().cast<SetAdminMode>();

    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await emit(const LinkState(_server, LinkReady()));
    await emit(HostProfileChanged(_server, HostProfile()));
    expect(asked().map((r) => (r.serverId, r.enabled)), [(_server, true)]);

    // The engine asks for the password, as for the header's chip.
    await emit(const AdminModeState(_server, AdminModePhase.awaitingPassword));
    await emit(
      const Prompt(
        promptId: 'p-1',
        serverId: _server,
        host: 'web-1.example',
        port: 22,
        request: ElevationPromptRequest(user: 'deploy'),
      ),
    );
    expect(find.text('Admin password for web-1.example'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Admin password for web-1.example'), findsNothing);
    await emit(
      const AdminModeState(
        _server,
        AdminModePhase.failed,
        failure: AdminFailure.cancelled,
      ),
    );

    await emit(const LinkState(_server, LinkConnecting()));
    await emit(const LinkState(_server, LinkReady()));
    await emit(HostProfileChanged(_server, HostProfile()));
    expect(asked(), hasLength(1));
    expect(find.text('Admin password for web-1.example'), findsNothing);
  });
}
