import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart' show loadBundledMonoFonts;
import 'package:ghost_ui/ghost_ui.dart' show contrastRatio;
import 'package:klabautermann_app/controllers/docker_endpoint_choices.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/access/access_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../support/charts.dart';
import '../support/docker.dart';
import '../support/fake_engine.dart';
import '../support/harness.dart';
import 'profiles.dart';

const _desktop = Size(1280, 800);
const _phone = Size(390, 800);

const _notChecked =
    'Not checked yet. Klabautermann checks access after it connects to this '
    'server.';

/// [twoServers] as the engine's catalog lists them.
const _web1Entry = FleetEntry(
  serverId: 'srv-1',
  label: 'web-1',
  host: 'web-1.example',
  port: 22,
  origin: FleetEntryOrigin.sshConfig,
);
const _db1Entry = FleetEntry(
  serverId: 'srv-2',
  label: 'db-1',
  host: '10.0.0.4',
  port: 22,
  origin: FleetEntryOrigin.sshConfig,
);

/// Pumps the app at [size], opens web-1 (srv-1) and, when [profile] is
/// given, delivers it as the probe's answer.
Future<AppHarness> _openWeb1(
  WidgetTester tester,
  Size size, {
  HostProfile? profile,
}) async {
  final harness = await pumpApp(tester, size: size, servers: twoServers);
  await tester.tap(find.text('web-1'));
  await tester.pumpAndSettle();
  if (profile != null) {
    harness.engine.emit(HostProfileChanged('srv-1', profile));
    await tester.pumpAndSettle();
  }
  return harness;
}

Future<void> _openTab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(TabBar),
    matching: find.text(label),
  );
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// What the app put on the clipboard, in order.
List<String> _recordClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

/// CN-24, SAF-08 and CN-09 (03 §10.4, D51): the Access tab, the panels the
/// access rules hide and the Docker tab's gate.
void main() {
  testWidgets('lists every right as unknown until the probe answers, '
      'then its state, reason and fix', (tester) async {
    final harness = await _openWeb1(tester, _desktop);
    await _openTab(tester, 'Access');

    expect(
      find.text(
        'Klabautermann never runs these fix commands. Copy one and run it '
        'yourself on the server.',
      ),
      findsOneWidget,
    );
    expect(find.text('Root-equivalent access'), findsOneWidget);
    expect(find.text(_notChecked), findsOneWidget);
    expect(find.text('Unknown'), findsNWidgets(AccessItem.values.length));
    expect(find.text('Copy command'), findsNothing);

    harness.engine.emit(HostProfileChanged('srv-1', debianHost()));
    await tester.pumpAndSettle();
    expect(find.text(_notChecked), findsNothing);

    // State in a word and an icon shape, never colour alone; the row is one
    // node in reading order.
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Passwordless sudo\nMissing\nRoot-equivalent\nsudo asks'),
      ),
      findsOneWidget,
    );
    expect(find.text('Missing'), findsNWidgets(3));
    expect(find.text('OK'), findsNWidgets(2));
    expect(find.text('Unknown'), findsNWidgets(2));
    expect(
      find.text(
        "Checked when Klabautermann looks for this server's Docker engine, "
        'after it connects.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        "Checked once Klabautermann reaches this server's Docker engine.",
      ),
      findsOneWidget,
    );
    expect(
      find.text('Version 252: unit and timer lists are read in full.'),
      findsOneWidget,
    );
    expect(find.text('sudo usermod -aG systemd-journal alice'), findsOneWidget);
    expect(find.text('sudo usermod -aG docker alice'), findsOneWidget);
    // SAF-08: docker-group advice never comes without its notice.
    expect(
      find.text(
        'Members of the docker group are root-equivalent. A rootless '
        'engine, which equals your user, is the safer choice.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Docker, rootful at /var/run/docker.sock'),
      findsOneWidget,
    );
    expect(find.text('Your account cannot use it.'), findsOneWidget);
  });

  group('the Docker endpoint\'s rows (CN-24, CN-09)', () {
    Finder row(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(MergeSemantics),
    );

    String rowText(WidgetTester tester, String title) => tester
        .widgetList<Text>(
          find.descendant(of: row(title).first, matching: find.byType(Text)),
        )
        .map((text) => text.data)
        .join('\n');

    List<DockerQuery> composeQueries(AppHarness harness) => [
      for (final query in harness.engine.sentOfType<DockerQuery>().cast())
        if (query.query is DockerComposeQuery) query,
    ];

    testWidgets('streamlocal follows the route, and compose is read once the '
        'endpoint is ready', (tester) async {
      final harness = await _openWeb1(tester, _desktop, profile: debianHost());
      await _openTab(tester, 'Access');
      expect(composeQueries(harness), isEmpty);

      harness.engine.emit(dockerReady('srv-1'));
      await tester.pumpAndSettle();
      expect(
        rowText(tester, 'Streamlocal forwarding'),
        'Streamlocal forwarding\nOK\nThe SSH server forwards the engine '
        'socket, the fastest route to Docker.',
      );
      expect(composeQueries(harness), hasLength(1));

      final cases = <DockerComposeCli, String>{
        const DockerComposeCli(
          pluginVersion: '2.29.7',
          standaloneVersion: '1.29.2',
        ): 'OK\nVersion 2.29.7.',
        const DockerComposeCli(standaloneVersion: '2.29.7'):
            'Missing\nOnly the standalone docker-compose 2.29.7 is '
            'installed. Stacks show read-only and their sources are not '
            'verified.',
        const DockerComposeCli(standaloneVersion: '1.29.2'):
            'Missing\nOnly Compose v1 (1.29.2) is installed, unmaintained '
            'since 2023. Stacks show read-only.',
        const DockerComposeCli():
            'Missing\nNeither docker compose nor '
            'docker-compose is installed.',
      };
      for (final MapEntry(key: cli, value: want) in cases.entries) {
        harness.engine.emit(
          DockerListChanged(
            serverId: 'srv-1',
            list: DockerWatchList.stacks,
            payload: DockerStacksPayload(
              const ComposeGrouping(projects: [], unmanaged: []),
              composeCli: cli,
            ),
            at: DateTime(2026, 10, 17),
          ),
        );
        await tester.pumpAndSettle();
        expect(rowText(tester, 'Compose plugin'), 'Compose plugin\n$want');
      }

      // A relay means sshd refused the socket; a new route reads the
      // compose CLIs again, and a failed check says so.
      harness.engine.emit(dockerReady('srv-1', rank: DockerRank.cliRelay));
      await tester.pumpAndSettle();
      expect(
        rowText(tester, 'Streamlocal forwarding'),
        startsWith('Streamlocal forwarding\nMissing\nThe SSH server refused'),
      );
      expect(composeQueries(harness), hasLength(2));
      harness.engine.emit(
        dockerAnswer(
          composeQueries(harness).last,
          const DockerQueryFailed(DockerQueryFailure.connectionFailed),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        rowText(tester, 'Compose plugin'),
        'Compose plugin\nUnknown\nThe check for docker compose failed on '
        'this server.',
      );
    });

    testWidgets('a socket the account cannot use, and a failure that tried '
        'none', (tester) async {
      final harness = await _openWeb1(tester, _desktop, profile: debianHost());
      await _openTab(tester, 'Access');

      harness.engine.emit(
        dockerNoRoute('srv-1', DockerNoRouteReason.socketDenied),
      );
      await tester.pumpAndSettle();
      expect(
        rowText(tester, 'Streamlocal forwarding'),
        'Streamlocal forwarding\nMissing\nThe SSH server could not open the '
        'engine socket as your account, which cannot use it. The Docker '
        'socket row shows how access is granted.',
      );

      harness.engine.emit(dockerNoRoute('srv-1', DockerNoRouteReason.noSocket));
      await tester.pumpAndSettle();
      expect(
        rowText(tester, 'Streamlocal forwarding'),
        'Streamlocal forwarding\nUnknown\nNot tested: no engine socket could '
        'be tried. The Docker tab says why.',
      );
      expect(composeQueries(harness), isEmpty);
    });

    testWidgets('Podman without a socket offers its user socket (CN-25)', (
      tester,
    ) async {
      await _openWeb1(
        tester,
        _desktop,
        profile: debianHost(
          overrides: {
            'tools': {'podman': '/usr/bin/podman'},
            'engineSockets': const <Object>[],
          },
        ),
      );
      await _openTab(tester, 'Access');
      expect(
        find.text('systemctl --user enable --now podman.socket'),
        findsOneWidget,
      );
    });

    testWidgets('the runtime row says a socket chosen on this device, and '
        'when it is not in use', (tester) async {
      const custom = '/srv/engine.sock';
      final choices = DockerEndpointChoices(
        stored: const {
          'srv-1': DockerEndpointOverride(
            DockerEndpointCustom(custom),
            endpoint: '',
          ),
        },
      );
      addTearDown(choices.dispose);
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: twoServers,
        dockerEndpointChoices: choices,
      );
      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      harness.engine.emit(HostProfileChanged('srv-1', debianHost()));
      await tester.pumpAndSettle();
      await _openTab(tester, 'Access');

      harness.engine.emit(
        DockerEndpointState(
          serverId: 'srv-1',
          phase: DockerEndpointPhase.ready,
          route: dockerReady('srv-1', socketPath: custom, mode: null).route,
          choice: const DockerEndpointCustom(custom),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        rowText(tester, 'Container runtime'),
        startsWith(
          'Container runtime\nOK\nChosen manually on this device: $custom',
        ),
      );

      harness.engine.emit(
        DockerEndpointState(
          serverId: 'srv-1',
          phase: DockerEndpointPhase.ready,
          route: dockerReady('srv-1').route,
          choice: const DockerEndpointCustom(custom),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        rowText(tester, 'Container runtime'),
        startsWith(
          'Container runtime\nMissing\n$custom was chosen on this device, '
          'but Docker does not use it',
        ),
      );
    });
  });

  testWidgets('copies a fix to the clipboard and sends the engine '
      'nothing', (tester) async {
    final copied = _recordClipboard(tester);
    final harness = await _openWeb1(tester, _desktop, profile: debianHost());
    await _openTab(tester, 'Access');
    final sentBefore = [...harness.engine.sent];

    // Each button names the right whose fix it copies (03 §10.10), after
    // its visible label, so a voice command that says the label finds it
    // (WCAG 2.5.3).
    for (final item in ['Journal group', 'Docker socket']) {
      expect(find.bySemanticsLabel('Copy command for $item'), findsOneWidget);
    }
    final copy = find.widgetWithText(OutlinedButton, 'Copy command').first;
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pumpAndSettle();

    expect(copied, ['sudo usermod -aG systemd-journal alice']);
    const confirmation = 'Copied. Run it yourself on the server.';
    expect(
      tester.getSemantics(find.text(confirmation)),
      isSemantics(label: confirmation, isLiveRegion: true),
    );
    expect(harness.engine.sent, sentBefore);
  });

  testWidgets('confirms only the last copy, which the clipboard '
      'holds', (tester) async {
    final copied = _recordClipboard(tester);
    const confirmation = 'Copied. Run it yourself on the server.';
    const dockerFix = 'sudo usermod -aG docker alice';
    await _openWeb1(tester, _desktop, profile: debianHost());
    await _openTab(tester, 'Access');
    for (final item in ['Journal group', 'Docker socket']) {
      final copy = find.bySemanticsLabel('Copy command for $item');
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
    }

    expect(copied, ['sudo usermod -aG systemd-journal alice', dockerFix]);
    // The Docker row's, under its fix: the journal row's would be stale.
    expect(find.text(confirmation), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(confirmation)).dy,
      greaterThan(tester.getTopLeft(find.text(dockerFix)).dy),
    );
  });

  testWidgets('confirms a copy on its own server only', (tester) async {
    _recordClipboard(tester);
    const confirmation = 'Copied. Run it yourself on the server.';
    final harness = await _openWeb1(tester, _desktop, profile: debianHost());
    harness.engine.emit(HostProfileChanged('srv-2', debianHost()));
    await _openTab(tester, 'Access');
    final copy = find.widgetWithText(OutlinedButton, 'Copy command').first;
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(find.text(confirmation), findsOneWidget);

    // db-1's fix reads the same, but nothing was copied there.
    await tester.tap(find.text('db-1'));
    await tester.pumpAndSettle();
    expect(find.byType(AccessPanel), findsOneWidget);
    expect(find.text('sudo usermod -aG systemd-journal alice'), findsOneWidget);
    expect(find.text(confirmation), findsNothing);
  });

  testWidgets('drops its confirmation when the clipboard refuses a '
      'copy', (tester) async {
    // As the Windows embedder answers while another process holds the
    // clipboard and OpenClipboard fails (its platform_handler.cc).
    var refuse = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && refuse) {
          throw PlatformException(
            code: 'Clipboard error',
            message: 'Unable to open clipboard',
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const confirmation = 'Copied. Run it yourself on the server.';
    await _openWeb1(tester, _desktop, profile: debianHost());
    await _openTab(tester, 'Access');
    final copy = find.widgetWithText(OutlinedButton, 'Copy command').first;
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(find.text(confirmation), findsOneWidget);

    // The clipboard still holds the earlier text, so the row must not
    // say this copy worked, and says it did not.
    refuse = true;
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(confirmation), findsNothing);
    const failure =
        'Not copied. The clipboard still holds its earlier text; try again '
        'before you paste.';
    expect(
      tester.getSemantics(find.text(failure)),
      isSemantics(label: failure, isLiveRegion: true),
    );

    // A copy that works replaces it.
    refuse = false;
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(find.text(failure), findsNothing);
    expect(find.text(confirmation), findsOneWidget);
  });

  testWidgets('says the server lacks sudo and doas only when the probe '
      'found neither', (tester) async {
    const absent = 'Run this as root: the server has neither sudo nor doas.';
    const unknown =
        'Run this as root. The probe could not tell whether the server '
        'has sudo or doas.';
    final harness = await _openWeb1(
      tester,
      _desktop,
      profile: debianHost(
        overrides: {'sudoKind': null, 'sudoNonInteractive': null},
      ),
    );
    await _openTab(tester, 'Access');

    // Elevation unanswered: the row says unknown, and so does the note.
    expect(find.text('usermod -aG systemd-journal alice'), findsOneWidget);
    expect(find.text(unknown), findsNWidgets(2));
    expect(find.text(absent), findsNothing);

    harness.engine.emit(
      HostProfileChanged(
        'srv-1',
        debianHost(
          overrides: {
            'sudoKind': 'none',
            'sudoNonInteractive': null,
            'doasPresent': false,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Neither sudo nor doas is installed.'), findsOneWidget);
    expect(find.text(absent), findsNWidgets(2));
    expect(find.text(unknown), findsNothing);
  });

  testWidgets('words the systemd tiers with the version', (tester) async {
    final engine = FakeEngineClient();
    final monitoring = MonitoringController(engine);
    addTearDown(() async {
      monitoring.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      _frame(
        Brightness.light,
        AccessPanel(monitoring: monitoring, serverId: 'srv-1'),
      ),
    );

    for (final (version, wording) in [
      (
        240,
        'Version 240: older than 246, so unit and timer lists are read from '
            'text output.',
      ),
      (238, 'Version 238 is older than any tested version (239).'),
    ]) {
      engine.emit(
        HostProfileChanged(
          'srv-1',
          debianHost(overrides: {'systemdVersion': version}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(wording), findsOneWidget);
    }
  });

  testWidgets('hides a panel the host cannot serve and links to the '
      'Access tab', (tester) async {
    final harness = await _openWeb1(
      tester,
      _desktop,
      profile: alpineContainer(),
    );
    final subscribed = harness.engine.sentOfType<Subscribe>().length;

    await _openTab(tester, 'Services');
    expect(
      find.text('Services is not available on this server'),
      findsOneWidget,
    );
    expect(find.text('This server does not run systemd.'), findsOneWidget);
    // A hidden panel samples nothing.
    expect(harness.engine.sentOfType<Subscribe>(), hasLength(subscribed));

    await tester.tap(find.text('Open Access'));
    await tester.pumpAndSettle();
    expect(find.byType(AccessPanel), findsOneWidget);
    expect(
      find.text(
        'You log in as root, so no elevation or group is '
        'needed.',
      ),
      findsWidgets,
    );
  });

  testWidgets('moves the keyboard into the Access tab from a hidden '
      'panel\'s link', (tester) async {
    await _openWeb1(
      tester,
      _desktop,
      profile: debianHost(overrides: {'systemdDir': false}),
    );
    await _openTab(tester, 'Services');
    Focus.of(tester.element(find.text('Open Access'))).requestFocus();
    await tester.pump();

    // The link hides with its panel (03 §10.10).
    bool focusInAccess() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<AccessPanel>() !=
        null;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(AccessPanel), findsOneWidget);
    expect(focusInAccess(), isTrue);

    // From there, Tab reaches its first control.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(focusInAccess(), isTrue);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<OutlinedButton>(),
      isNotNull,
    );
  });

  testWidgets('Tab walks from the tab strip past the Access tab onto its '
      'first control', (tester) async {
    await _openWeb1(tester, _desktop, profile: debianHost());
    await _openTab(tester, 'Access');
    final tab = find.descendant(
      of: find.byType(TabBar),
      matching: find.text('Access'),
    );
    Focus.of(tester.element(tab)).requestFocus();
    await tester.pump();

    // The tab's own focus node, there for a hidden panel's link, is no
    // stop: the first focus inside the tab is its first copy button.
    BuildContext? focused() => FocusManager.instance.primaryFocus?.context;
    for (var presses = 0; presses < 20; presses++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (focused()?.findAncestorWidgetOfExactType<AccessPanel>() != null) {
        break;
      }
    }
    expect(focused()?.findAncestorWidgetOfExactType<AccessPanel>(), isNotNull);
    expect(
      focused()?.findAncestorWidgetOfExactType<OutlinedButton>(),
      isNotNull,
    );
  });

  testWidgets('keeps its controls together in Tab order beside another '
      'pane', (tester) async {
    final engine = FakeEngineClient();
    final monitoring = MonitoringController(engine);
    addTearDown(() async {
      monitoring.dispose();
      await engine.close();
    });
    tester.view.physicalSize = _desktop;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _frame(
        Brightness.light,
        Row(
          children: [
            Expanded(
              child: AccessPanel(monitoring: monitoring, serverId: 'srv-1'),
            ),
            // A pane whose buttons sit level with the tab's rows.
            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final name in ['top', 'middle', 'bottom'])
                  TextButton(onPressed: () {}, child: Text(name)),
              ],
            ),
          ],
        ),
      ),
    );
    engine.emit(HostProfileChanged('srv-1', debianHost()));
    await tester.pumpAndSettle();

    Focus.of(tester.element(find.text('bottom'))).requestFocus();
    await tester.pump();
    String stop() {
      final context = FocusManager.instance.primaryFocus!.context!;
      if (context.findAncestorWidgetOfExactType<OutlinedButton>() != null) {
        return 'copy';
      }
      if (context.findAncestorWidgetOfExactType<TextButton>() != null) {
        return 'side';
      }
      return 'other';
    }

    final stops = <String>[];
    for (var presses = 0; presses < 5; presses++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      stops.add(stop());
    }
    expect(stops, ['copy', 'copy', 'side', 'side', 'side']);
  });

  testWidgets('gates the Docker tab on its endpoint, not on the probe', (
    tester,
  ) async {
    final harness = await _openWeb1(tester, _desktop);
    await _openTab(tester, 'Docker');
    expect(find.text('Waiting for the connection'), findsOneWidget);

    harness.engine.emit(HostProfileChanged('srv-1', alpineContainer()));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for the connection'), findsOneWidget);
    expect(find.text('Copy command'), findsNothing);

    harness.engine.emit(
      const DockerEndpointState(
        serverId: 'srv-1',
        phase: DockerEndpointPhase.failed,
        failure: DockerEndpointFailure.noRoute,
        noRouteReason: DockerNoRouteReason.socketDenied,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Docker is not available on this server'), findsOneWidget);
    await tester.tap(find.text('Open Access'));
    await tester.pumpAndSettle();
    expect(find.byType(AccessPanel), findsOneWidget);
  });

  testWidgets('a phone gates Docker and pushes Access from a hidden '
      'panel', (tester) async {
    await _openWeb1(
      tester,
      _phone,
      profile: alpineContainer(tools: {'tail': null}),
    );

    await tester.tap(find.text('Docker'));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for the connection'), findsOneWidget);

    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();
    expect(find.text('Logs is not available on this server'), findsOneWidget);
    expect(find.text('This server has no tail command.'), findsOneWidget);

    await tester.tap(find.text('Open Access'));
    await tester.pumpAndSettle();
    expect(find.text('Access on web-1'), findsOneWidget);
    expect(find.byType(AccessPanel), findsOneWidget);
  });

  testWidgets('a pushed Access screen closes with its server out of the '
      'fleet, and opens on the new profile once it is back', (tester) async {
    const rootLogin = 'You log in as root, so no elevation or group is needed.';
    final harness = await _openWeb1(
      tester,
      _phone,
      profile: alpineContainer(tools: {'tail': null}),
    );
    Future<void> openAccess() async {
      await tester.tap(find.text('Logs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Access'));
      await tester.pumpAndSettle();
    }

    await openAccess();
    expect(find.text(rootLogin), findsWidgets);

    // SYN-08 (task #50): the server's screens close back to the fleet.
    harness.engine.emit(CatalogReplaced(const [_db1Entry]));
    await tester.pumpAndSettle();
    expect(find.byType(AccessPanel), findsNothing);
    expect(find.text('db-1'), findsOneWidget);

    // Back, the profile left with it, so a new one shows.
    harness.engine
      ..emit(CatalogReplaced(const [_web1Entry, _db1Entry]))
      ..emit(
        HostProfileChanged('srv-1', alpineContainer(tools: {'tail': null})),
      );
    await tester.pumpAndSettle();
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await openAccess();
    expect(find.text(rootLogin), findsWidgets);
    harness.engine.emit(HostProfileChanged('srv-1', debianHost()));
    await tester.pumpAndSettle();
    expect(find.text(rootLogin), findsNothing);
    expect(find.text('sudo usermod -aG systemd-journal alice'), findsOneWidget);
  });

  testWidgets('drops a server\'s profile when it leaves the fleet '
      '(SYN-08)', (tester) async {
    final harness = await _openWeb1(tester, _desktop, profile: debianHost());
    final profile = harness.monitoring.profileFor('srv-1');
    expect(profile.value, isNotNull);

    harness.engine.emit(CatalogReplaced(const [_db1Entry]));
    await tester.pumpAndSettle();
    harness.engine.emit(HostProfileChanged('srv-1', debianHost()));
    await tester.pumpAndSettle();
    expect(harness.monitoring.profileFor('srv-1').value, isNull);
  });

  for (final size in [_desktop, _phone]) {
    testWidgets('lays out at 200 % text on ${size.width.toInt()} px', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final engine = FakeEngineClient();
      final fleet = FleetController(engine, servers: twoServers);
      final monitoring = MonitoringController(engine);
      addTearDown(() async {
        monitoring.dispose();
        fleet.dispose();
        await engine.close();
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _frame(
          Brightness.light,
          AccessPage(
            fleet: fleet,
            monitoring: monitoring,
            serverId: 'srv-1',
            serverName: 'web-1',
          ),
        ),
      );
      engine.emit(HostProfileChanged('srv-1', debianHost()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Container runtime'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('quotes a fix word a shell could expand', () {
    // zsh expands a leading `=word` to a command path (its EQUALS option).
    expect(
      fixCommandText(AccessFix(['usermod', '=ls', '50%'], FixElevation.sudo)),
      "sudo usermod '=ls' '50%'",
    );
  });

  test('draws its marks at contrast in light and dark', () {
    for (final brightness in Brightness.values) {
      final scheme = chartTheme(brightness).colorScheme;
      final surface = scheme.surface;
      // The state colours draw the icon and the state word beside it.
      for (final state in [
        scheme.primary,
        scheme.error,
        scheme.onSurfaceVariant,
      ]) {
        expect(contrastRatio(state, surface), greaterThanOrEqualTo(4.5));
      }
      expect(
        contrastRatio(scheme.onErrorContainer, scheme.errorContainer),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(scheme.onSecondaryContainer, scheme.secondaryContainer),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(scheme.onSurface, scheme.surfaceContainerHighest),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  group('golden', () {
    setUpAll(() async {
      await loadGoldenFonts();
      // The fix commands draw in the bundled monospace family.
      await loadBundledMonoFonts();
    });

    for (final (name, size) in [
      ('desktop', const Size(720, 1040)),
      ('phone', const Size(390, 1240)),
    ]) {
      for (final brightness in Brightness.values) {
        testWidgets('$name, ${brightness.name}', (tester) async {
          final engine = FakeEngineClient();
          final monitoring = MonitoringController(engine);
          addTearDown(() async {
            monitoring.dispose();
            await engine.close();
          });
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            _frame(
              brightness,
              AccessPanel(monitoring: monitoring, serverId: 'srv-1'),
              fontFamily: goldenFontFamily,
            ),
          );
          engine.emit(HostProfileChanged('srv-1', debianHost()));
          await tester.pumpAndSettle();

          await expectLater(
            find.byType(AccessPanel),
            matchesGoldenFile(
              'goldens/access_panel_${name}_${brightness.name}.png',
            ),
          );
        }, skip: !Platform.isLinux);
      }
    }
  });
}

/// [child] in the app's theme and localizations, outside the shell.
Widget _frame(Brightness brightness, Widget child, {String? fontFamily}) {
  final theme = chartTheme(brightness, fontFamily: fontFamily);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Material(color: theme.colorScheme.surface, child: child),
  );
}
