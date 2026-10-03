import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/local_shell_service.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_app/ui/server_status_dot.dart';
import 'package:seance_app/ui/server_tile.dart';
import 'package:seance_app/ui/sidebar/sidebar_kit.dart';
import 'package:seance_core/seance_core.dart';

/// The app-side half of the local shell: which platforms offer it, what the
/// session model says about a tab with no server, and the pinned list row.
///
/// The pty itself is never started here — `flutter test` runs on the host Dart
/// VM, where the plugin's native library does not exist. That is exactly why
/// [LocalShellService.launch] is injectable; `LocalShellSession`'s wiring is
/// covered against a fake in `packages/seance_core/test/local_shell_test.dart`.
void main() {
  LocalShellService service({
    required LocalShellPlatform platform,
    Map<String, String> environment = const {},
  }) => LocalShellService(
    platform: platform,
    environment: environment,
    launch: (_, __) async => throw StateError('not started in tests'),
  );

  group('availability', () {
    test('offered on Linux and macOS, refused with a reason elsewhere', () {
      for (final platform in LocalShellPlatform.values) {
        final local = service(platform: platform);
        if (platform == LocalShellPlatform.linux ||
            platform == LocalShellPlatform.macos) {
          expect(local.supported, isTrue, reason: '$platform');
          expect(local.unavailableReason, isEmpty, reason: '$platform');
        } else {
          expect(local.supported, isFalse, reason: '$platform');
          expect(local.unavailableReason, isNotEmpty, reason: '$platform');
        }
      }
    });

    test('the setting alone never makes an unsupported platform offer it', () {
      // A settings file is device-local but portable: enabling this on a
      // laptop must not put a dead row in a phone's list.
      expect(
        service(
          platform: LocalShellPlatform.ios,
        ).availableWhen(enabledInSettings: true),
        isFalse,
      );
      expect(
        service(
          platform: LocalShellPlatform.linux,
        ).availableWhen(enabledInSettings: true),
        isTrue,
      );
      expect(
        service(
          platform: LocalShellPlatform.linux,
        ).availableWhen(enabledInSettings: false),
        isFalse,
      );
    });

    test('the host platform maps onto the core enum', () {
      // Registered before the loop: an expect that throws must still put the
      // override back, or every widget test after this one runs on the wrong
      // platform and fails for reasons that have nothing to do with them.
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final entry in const {
        TargetPlatform.linux: LocalShellPlatform.linux,
        TargetPlatform.macOS: LocalShellPlatform.macos,
        TargetPlatform.windows: LocalShellPlatform.windows,
        TargetPlatform.android: LocalShellPlatform.android,
        TargetPlatform.iOS: LocalShellPlatform.ios,
        TargetPlatform.fuchsia: LocalShellPlatform.unknown,
      }.entries) {
        debugDefaultTargetPlatformOverride = entry.key;
        expect(LocalShellService.hostPlatform(), entry.value);
      }
    });
  });

  group('the macOS sandbox', () {
    test('is detected from the container variable, and only on macOS', () {
      const sandboxEnv = {'APP_SANDBOX_CONTAINER_ID': 'com.lkm.seance-app'};
      expect(
        service(
          platform: LocalShellPlatform.macos,
          environment: sandboxEnv,
        ).sandboxed,
        isTrue,
      );
      expect(service(platform: LocalShellPlatform.macos).sandboxed, isFalse);
      // The variable can only mean something on macOS; a stray one elsewhere
      // must not produce a warning about a sandbox that isn't there.
      expect(
        service(
          platform: LocalShellPlatform.linux,
          environment: sandboxEnv,
        ).sandboxed,
        isFalse,
      );
    });

    test('a sandboxed session is warned in its own scrollback', () {
      final notice = service(
        platform: LocalShellPlatform.macos,
        environment: const {'APP_SANDBOX_CONTAINER_ID': 'x'},
      ).sandboxNotice;
      expect(notice, isNotNull);
      expect(notice, contains(r'$HOME'));
      // A pty needs the carriage return; a bare \n would leave the shell's
      // first prompt indented under the notice.
      expect(notice, endsWith('\r\n'));
      expect(service(platform: LocalShellPlatform.linux).sandboxNotice, isNull);
    });
  });

  group('the shell being run', () {
    test(r'is named from $SHELL, for the tab and the row', () {
      expect(
        service(
          platform: LocalShellPlatform.linux,
          environment: const {'SHELL': '/usr/bin/fish'},
        ).shellName,
        'fish',
      );
      expect(service(platform: LocalShellPlatform.macos).shellName, 'zsh');
    });
  });

  group('a local session in the tab model', () {
    final engines = <XtermTerminalEngine>[];
    TerminalSession local({String id = 'local-1', String? shell = 'zsh'}) {
      final engine = XtermTerminalEngine();
      engines.add(engine);
      return TerminalSession(
        id: id,
        serverId: kLocalShellServerId,
        shellName: shell,
        engine: engine,
      );
    }

    TerminalSession remote(String id, String serverId) {
      final engine = XtermTerminalEngine();
      engines.add(engine);
      return TerminalSession(
        id: id,
        serverId: serverId,
        config: ServerConfig(
          id: serverId,
          label: serverId,
          host: 'h',
          port: 22,
          username: 'u',
          createdAt: 0,
          updatedAt: 0,
        ),
        engine: engine,
      );
    }

    tearDown(() async {
      for (final e in engines) {
        await e.dispose();
      }
      engines.clear();
    });

    test('has no server, and never renders one', () {
      final session = local();
      expect(session.isLocal, isTrue);
      expect(session.config, isNull);
      expect(session.displayLabel, 'Local shell');
      expect(session.displayTarget, 'zsh · this machine');
      // The failure mode a stand-in ServerConfig would have produced.
      expect(session.displayTarget, isNot(contains('@')));
      expect(session.displayTarget, isNot(contains(':0')));
    });

    test('falls back to a generic name when the shell is unknown', () {
      expect(local(shell: null).displayTarget, 'shell · this machine');
    });

    test('an SSH session still renders its target', () {
      final session = remote('a', 'srv');
      expect(session.isLocal, isFalse);
      expect(session.displayLabel, 'srv');
      expect(session.displayTarget, 'u@h:22');
    });

    test('local tabs group and stay contiguous like any server', () {
      final list = [
        remote('a1', 'A'),
        local(id: 'l1'),
        remote('b1', 'B'),
        local(id: 'l2'),
      ];
      expect(
        AppState.tabsForServerIn(list, kLocalShellServerId).map((s) => s.id),
        ['l1', 'l2'],
      );
      expect(AppState.insertIndexFor(list, kLocalShellServerId), 4);
    });

    test('closing a local tab falls back to its sibling, then to a server', () {
      final first = local(id: 'l1');
      final second = local(id: 'l2');
      final server = remote('a1', 'A');
      expect(
        AppState.fallbackAfterClosing(
          closed: first,
          siblingsBefore: [first, second],
          remaining: [second, server],
          lastTabForServer: const {},
        )?.id,
        'l2',
      );
      expect(
        AppState.fallbackAfterClosing(
          closed: second,
          siblingsBefore: [second],
          remaining: [server],
          lastTabForServer: const {},
        )?.id,
        'a1',
      );
    });

    test('an exit status is carried only by a local session', () {
      final session = local()..shellExitCode = 130;
      expect(session.shellExitCode, 130);
      expect(remote('a', 'srv').shellExitCode, isNull);
    });
  });

  group('the pinned list row', () {
    Future<void> pump(
      WidgetTester tester, {
      int tabCount = 0,
      ServerDot dot = ServerDot.none,
      SidebarKitDensity density = SidebarKitDensity.comfortable,
      VoidCallback? onTap,
      VoidCallback? onNewTab,
      VoidCallback? onCloseAll,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(),
        home: Scaffold(
          body: SidebarKitScope(
            strings: serverSidebarStrings,
            density: density,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 260,
                child: LocalShellTile(
                  dot: dot,
                  tabCount: tabCount,
                  shellName: 'zsh',
                  selected: false,
                  onTap: onTap ?? () {},
                  onNewTab: onNewTab ?? () {},
                  onCloseAll: onCloseAll ?? () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    /// The row's kit verbs, the way a desktop right-click opens them.
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(
        find.byType(SidebarRow),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    SidebarRow row(WidgetTester tester) =>
        tester.widget<SidebarRow>(find.byType(SidebarRow));

    MenuItemButton verb(WidgetTester tester, String label) =>
        tester.widget<MenuItemButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(MenuItemButton),
          ),
        );

    testWidgets('names this machine and the shell it runs', (tester) async {
      await pump(tester);
      // Middle-ellipsized at rail width, so the row itself carries it.
      expect(row(tester).title, 'Local shell');
      expect(find.text('zsh · this machine'), findsOneWidget);
      // No reachability dot: this machine is demonstrably here.
      expect(row(tester).status, isNull);
    });

    testWidgets('wears the same badge shape as a server row', (tester) async {
      // Structurally a server row — the kit's mark in the mark's place — so
      // the list reads as one thing. The glyph is what says which kind it is.
      await pump(tester);
      expect(find.byType(LocalShellRailMark), findsOneWidget);
      expect(find.byIcon(Icons.terminal), findsOneWidget);
    });

    testWidgets('counts its tabs only once there is more than one', (
      tester,
    ) async {
      await pump(tester, tabCount: 1);
      expect(find.text('×1'), findsNothing);
      await pump(tester, tabCount: 3);
      expect(find.text('×3'), findsOneWidget);
    });

    testWidgets('opens on tap', (tester) async {
      var opened = 0;
      await pump(tester, onTap: () => opened++);
      await tester.tap(find.byType(SidebarRow));
      expect(opened, 1);
    });

    testWidgets('offers a new shell, and a greyed close, when idle', (
      tester,
    ) async {
      await pump(tester);
      await openMenu(tester);
      expect(find.text('New shell'), findsOneWidget);
      // Nothing is open: Close stays, greyed, so the menu keeps its shape —
      // the same courtesy the server rows give a dead Disconnect.
      expect(verb(tester, 'Close').onPressed, isNull);
    });

    testWidgets('offers to close every open shell at once', (tester) async {
      var closed = 0;
      await pump(tester, tabCount: 2, onCloseAll: () => closed++);
      await openMenu(tester);
      expect(verb(tester, 'Close all shells').onPressed, isNotNull);
      await tester.tap(find.text('Close all shells'));
      await tester.pumpAndSettle();
      expect(closed, 1);
    });

    testWidgets('a starting shell wears the connecting dot', (tester) async {
      await pump(tester, tabCount: 1, dot: ServerDot.connecting);
      final context = tester.element(find.byType(SidebarRow));
      expect(row(tester).status?.color, StatusColors.connecting(context));
      expect(row(tester).markRing, isNull);
    });

    testWidgets('a running shell wears the connected dot and ring', (
      tester,
    ) async {
      await pump(tester, tabCount: 1, dot: ServerDot.connected);
      final context = tester.element(find.byType(SidebarRow));
      expect(row(tester).status?.color, StatusColors.online(context));
      expect(row(tester).markRing, StatusColors.online(context));
    });
  });

  group('the setting', () {
    test('is off by default and round-trips through JSON', () {
      expect(AppSettings().localShell, isFalse);
      final on = AppSettings(localShell: true);
      expect(AppSettings.fromJson(on.toJson()).localShell, isTrue);
      expect(
        AppSettings.fromJson(
          AppSettings(localShell: false).toJson(),
        ).localShell,
        isFalse,
      );
    });

    test('an older settings file without the key stays off', () {
      final json = AppSettings().toJson()..remove('localShell');
      expect(AppSettings.fromJson(json).localShell, isFalse);
    });
  });

  /// The kill policy behind `FlutterPtyLocalPty.kill`. These tests pin the
  /// *sequence* only — hangup always runs, SIGKILL is armed only while the
  /// child is not proven dead. Whether a hangup or a signal actually ends
  /// a process is an OS question the fake cannot answer; that half is
  /// covered by the real-pty test in `local_shell_native_test.dart`.
  group('pty termination', () {
    List<ProcessSignal> sent = [];
    var hangups = 0;

    bool Function(ProcessSignal) recorder() => (signal) {
      sent.add(signal);
      return true;
    };
    void Function() hangupRecorder() => () => hangups++;

    setUp(() {
      sent = [];
      hangups = 0;
    });

    test('hangs up, and sends no signals to an already-reaped child', () {
      PtyTermination(
        hasExited: () => true,
        send: recorder(),
        hangup: hangupRecorder(),
      ).run();
      expect(hangups, 1);
      // The pid of a reaped child may already be recycled — nothing is
      // signalled, not even the benign-looking SIGHUP.
      expect(sent, isEmpty);
    });

    test('a live child gets the hangup plus a SIGKILL after the grace',
        () async {
      PtyTermination(
        hasExited: () => false,
        send: recorder(),
        hangup: hangupRecorder(),
        grace: const Duration(milliseconds: 50),
      ).run();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(hangups, 1);
      expect(sent, [ProcessSignal.sigkill]);
    });

    test('an exit inside the grace window cancels the escalation', () async {
      var exited = false;
      PtyTermination(
        hasExited: () => exited,
        send: recorder(),
        hangup: hangupRecorder(),
        grace: const Duration(milliseconds: 150),
      ).run();
      exited = true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(hangups, 1);
      expect(sent, isEmpty);
    });

    test('run() is idempotent — hangup and watchdog fire once', () async {
      final termination = PtyTermination(
        hasExited: () => false,
        send: recorder(),
        hangup: hangupRecorder(),
        grace: const Duration(milliseconds: 50),
      )..run();
      termination.run();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(hangups, 1);
      expect(sent, [ProcessSignal.sigkill]);
    });

    test('a send that reports failure does not throw', () async {
      PtyTermination(
        hasExited: () => false,
        send: (_) => false,
        hangup: hangupRecorder(),
        grace: const Duration(milliseconds: 50),
      ).run();
      PtyTermination(
        hasExited: () => false,
        send: (_) => throw StateError('no such process'),
        hangup: hangupRecorder(),
        grace: const Duration(milliseconds: 50),
      ).run();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(hangups, 2);
    });
  });

  /// [AppState.setLocalShellEnabled] turns live shells off, so its ordering
  /// with the save matters: only a durable "off" may tear the tabs down.
  /// The shells are fakes — the launcher seam is covered elsewhere — and the
  /// save failure is a real thrown error from `services.saveSettings`.
  group('toggling the setting', () {
    late _Services services;
    late AppState state;
    final engines = <XtermTerminalEngine>[];
    final transports = <_FakeTransport>[];

    TerminalSession localTab(String id) {
      final engine = XtermTerminalEngine();
      engines.add(engine);
      final transport = _FakeTransport(engine);
      transports.add(transport);
      final tab = TerminalSession(
        id: id,
        serverId: kLocalShellServerId,
        shellName: 'zsh',
        engine: engine,
      )..session = transport;
      state.tabs.add(tab);
      return tab;
    }

    setUp(() {
      services = _Services()..settings.localShell = true;
      state = AppState(services);
    });

    tearDown(() async {
      state.dispose();
      for (final e in engines) {
        await e.dispose();
      }
      engines.clear();
      transports.clear();
    });

    test('a durable off closes every live shell', () async {
      localTab('l1');
      localTab('l2');
      await state.setLocalShellEnabled(false);

      expect(services.settings.localShell, isFalse);
      expect(state.tabs, isEmpty);
      expect(transports.every((t) => t.closed), isTrue);
      expect(services.saves, 1);
    });

    test('a failed save keeps the shells and puts the switch back', () async {
      final tab = localTab('l1');
      services.failSaves = true;

      await expectLater(
        state.setLocalShellEnabled(false),
        throwsA(isA<StateError>()),
      );
      expect(services.settings.localShell, isTrue,
          reason: 'the flag reverts when the save did not land');
      expect(state.tabs, contains(tab),
          reason: 'an off that never persisted must not kill the shells');
      expect(transports.single.closed, isFalse);
    });

    test('a newer toggle during the save keeps the shells it re-enabled',
        () async {
      localTab('l1');
      final gate = Completer<void>();
      services.saveGate = gate;

      final disabling = state.setLocalShellEnabled(false);
      await pumpEventQueue();
      expect(services.settings.localShell, isFalse);

      // The user flips it back on while the off-save is still in flight.
      await state.setLocalShellEnabled(true);
      gate.complete();
      await disabling;

      expect(services.settings.localShell, isTrue);
      expect(state.tabs, hasLength(1),
          reason: 'the re-enabled shells belong to the newer toggle');
      expect(transports.single.closed, isFalse);
      expect(services.saves, 2);
    });
  });
}

/// A services seam for the toggle tests: `settings` is real, `saveSettings`
/// can be held open or made to fail, everything else is unreachable.
class _Services implements AppServices {
  @override
  final AppSettings settings = AppSettings();
  @override
  final ProbeService probe = ProbeService();

  /// Set once: the next save parks until this completes, then clears itself.
  Completer<void>? saveGate;
  bool failSaves = false;
  int saves = 0;

  @override
  Future<void> saveSettings() async {
    saves++;
    final gate = saveGate;
    saveGate = null;
    if (gate != null) await gate.future;
    if (failSaves) throw StateError('settings write failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The transport half of a local tab: [close] disposes its engine, matching
/// the contract [AppState] leans on.
class _FakeTransport implements SessionTransport {
  _FakeTransport(this.engine);

  final XtermTerminalEngine engine;

  @override
  bool get isClosed => closed;
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
    await engine.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
