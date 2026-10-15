import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:ghost_ui/ghost_ui.dart' show SelectedTabView;
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/server_header.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'access/profiles.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';

/// A Debian host with a rootful Docker and a rootless Podman socket.
final _twoEngines = debianHost(
  overrides: {
    'engineSockets': [
      for (final path in [
        '/var/run/docker.sock',
        '/run/user/1000/podman/podman.sock',
      ])
        {'path': path, 'exists': true, 'writable': false},
    ],
  },
);

const _twoEnginesText =
    'Runtime: Docker, rootful; Podman, rootless (Podman can also answer on '
    'Docker\'s socket path)';

Finder _inHeader(Finder finder) =>
    find.descendant(of: find.byType(ServerHeader), matching: finder);

/// The link state's dot: the one circle it draws, or null for none.
BoxDecoration? _dot(WidgetTester tester) => tester
    .widgetList<Container>(
      find.descendant(
        of: find.byType(ServerLinkState),
        matching: find.byType(Container),
      ),
    )
    .map((container) => container.decoration)
    .whereType<BoxDecoration>()
    .where((decoration) => decoration.shape == BoxShape.circle)
    .singleOrNull;

/// Whether the dot carries the bar of a refusal.
bool _dotBarred(WidgetTester tester) => find
    .descendant(
      of: find.byType(ServerLinkState),
      matching: find.byType(ColoredBox),
    )
    .evaluate()
    .isNotEmpty;

Future<AppHarness> _openWeb1(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final harness = await pumpApp(tester, size: size, servers: twoServers);
  await tester.tap(find.text('web-1'));
  await tester.pumpAndSettle();
  return harness;
}

/// 03 §10.2's server header: the link state, the coverage chip, the
/// detected runtime (CN-09) and a slot for client limitations.
void main() {
  test('the runtime reads as the Access tab derives it', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    String runtime(HostProfile? profile) => detectedRuntimeText(l10n, profile);
    expect(runtime(null), 'Runtime: not checked yet');
    // A socket at Docker's path carries the Access tab's caveat that
    // podman-docker may serve it (CN-09).
    expect(
      runtime(debianHost()),
      'Runtime: Docker, rootful (Podman can also answer on Docker\'s socket '
      'path)',
    );
    expect(runtime(alpineContainer()), 'Runtime: Podman, rootless');
    expect(runtime(_twoEngines), _twoEnginesText);
    expect(
      runtime(
        debianHost(
          overrides: {
            'engineSockets': const [],
            'tools': const {'docker': null, 'podman': null},
          },
        ),
      ),
      'Runtime: none found',
    );
    expect(
      runtime(
        debianHost(
          overrides: {
            'engineSockets': const [],
            'areaStatuses': const {'identity': 'ok', 'sockets': 'denied'},
          },
        ),
      ),
      'Runtime: unknown',
    );
  });

  testWidgets('the desktop header says the link state with a dot, an icon '
      'and a word, and the runtime once the probe answers', (tester) async {
    final harness = await _openWeb1(tester, const Size(1280, 800));

    expect(_inHeader(find.text('web-1')), findsOneWidget);
    expect(_inHeader(find.text('Disconnected')), findsOneWidget);
    expect(_inHeader(find.byIcon(Icons.link_off)), findsOneWidget);
    expect(_dot(tester), isNull, reason: 'nothing known, nothing to show');
    expect(_inHeader(find.text('Runtime: not checked yet')), findsOneWidget);

    harness.engine
      ..emit(const LinkState('srv-1', LinkReady()))
      ..emit(HostProfileChanged('srv-1', debianHost()));
    await tester.pumpAndSettle();
    final chrome = GhostChrome.of(
      tester.element(find.byType(ServerLinkState)),
      klabautermannThemeStyle,
    );
    expect(_inHeader(find.text('Connected')), findsOneWidget);
    expect(_inHeader(find.byIcon(Icons.link)), findsOneWidget);
    // Live truth: a solid dot.
    expect(_dot(tester)?.color, chrome.statusConnected);
    expect(_dot(tester)?.border, isNull);
    expect(_dotBarred(tester), isFalse);
    expect(
      find.bySemanticsLabel('Server status: Connected'),
      findsOneWidget,
      reason: 'the row says it in its own label',
    );
    expect(
      _inHeader(find.textContaining('Runtime: Docker, rootful (')),
      findsOneWidget,
    );

    // The rail rule: with no link, the probe's answer speaks, as on the
    // server's row.
    harness.engine
      ..emit(const LinkState('srv-1', LinkIdle()))
      ..emit(const Reachability('srv-1', ReachabilityStatus.online));
    await tester.pumpAndSettle();
    expect(_inHeader(find.text('Online')), findsOneWidget);
    expect(_inHeader(find.byIcon(Icons.cloud_done_outlined)), findsOneWidget);
    // A probe's observation: a ring.
    expect(_dot(tester)?.color, isNull);
    expect(
      _dot(tester)?.border,
      Border.all(color: chrome.statusConnected, width: 2),
    );

    // A refusal: the offline colour with a bar through the dot.
    harness.engine.emit(
      const LinkState('srv-1', LinkBlocked(LinkBlockedReason.hostKeyChanged)),
    );
    await tester.pumpAndSettle();
    expect(_dot(tester)?.color, chrome.statusFailed);
    expect(_dotBarred(tester), isTrue);
  });

  testWidgets('the coverage chip opens the coverage sheet', (tester) async {
    await _openWeb1(tester, const Size(1280, 800));

    final chip = _inHeader(find.text('T0: sampled only while open'));
    expect(chip, findsOneWidget);
    expect(
      tester.getSemantics(chip),
      matchesSemantics(
        label: 'T0: sampled only while open',
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
        onTapHint: 'Show coverage details',
      ),
    );
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.text('Coverage on this device'), findsOneWidget);
  });

  testWidgets('client-limitation messages show under the facts', (
    tester,
  ) async {
    final engine = FakeEngineClient();
    final fleet = FleetController(engine, servers: twoServers);
    final monitoring = MonitoringController(engine);
    addTearDown(() async {
      fleet.dispose();
      monitoring.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ServerHeader(
            server: twoServers.first,
            fleet: fleet,
            monitoring: monitoring,
            limitations: const ['First limitation', 'Second limitation'],
          ),
        ),
      ),
    );

    expect(find.text('First limitation'), findsOneWidget);
    expect(find.text('Second limitation'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNWidgets(2));
  });

  for (final (name, size) in [
    ('desktop', const Size(960, 700)),
    ('phone', const Size(390, 800)),
  ]) {
    testWidgets('the $name header wraps at 200 % text', (tester) async {
      final harness = await _openWeb1(tester, size, textScale: 2);
      harness.engine
        ..emit(const LinkState('srv-1', LinkReady()))
        ..emit(HostProfileChanged('srv-1', _twoEngines));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_inHeader(find.text(_twoEnginesText)), findsOneWidget);
      // The phone's app bar carries the name; the header does not repeat
      // it.
      expect(
        _inHeader(find.text('web-1')),
        name == 'phone' ? findsNothing : findsOneWidget,
      );
    });
  }

  // Short phone screens: landscape, a split screen and the smallest
  // portrait one. The header scrolls before it takes the panel's room.
  for (final size in const [
    Size(640, 360),
    Size(667, 375),
    Size(390, 500),
    Size(320, 568),
  ]) {
    testWidgets('a ${size.width.round()} x ${size.height.round()} phone '
        'keeps most of its body for the panel at 200 % text', (tester) async {
      final harness = await _openWeb1(tester, size, textScale: 2);
      harness.engine
        ..emit(const LinkState('srv-1', LinkReady()))
        ..emit(HostProfileChanged('srv-1', _twoEngines));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final panel = find.byType(SelectedTabView);
      final body = find.ancestor(of: panel, matching: find.byType(Column));
      expect(
        tester.getSize(panel).height,
        greaterThanOrEqualTo(tester.getSize(body.first).height * 0.6 - 0.5),
      );

      // What the header cuts off scrolls into view: its last line, the
      // runtime, ends inside it once scrolled to the end.
      final viewport = find
          .ancestor(
            of: find.byType(ServerHeader),
            matching: find.byType(Scrollable),
          )
          .first;
      final runtime = _inHeader(find.text(_twoEnginesText));
      await tester.drag(viewport, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(runtime).bottom,
        lessThanOrEqualTo(tester.getRect(viewport).bottom),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
