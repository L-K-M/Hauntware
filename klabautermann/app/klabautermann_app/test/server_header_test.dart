import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show DiagnosticsDebugCreator;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:ghost_ui/ghost_ui.dart' show SelectedTabView;
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/desktop_shell.dart';
import 'package:klabautermann_app/ui/fleet_rows.dart' show FleetServerList;
import 'package:klabautermann_app/ui/server_header.dart';
import 'package:klabautermann_app/ui/server_workspace.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'access/profiles.dart';
import 'support/harness.dart';
import 'support/link_failures.dart';

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

/// Whether [details] names the widget that raised it and that widget sits
/// outside every [T]. An error without a creator cannot be placed, so it
/// counts as inside.
bool _raisedOutside<T extends Widget>(FlutterErrorDetails details) {
  for (final node in details.informationCollector?.call() ?? const []) {
    if (node case DiagnosticsDebugCreator(
      value: DebugCreator(:final element),
    )) {
      return element.widget is! T &&
          element.findAncestorWidgetOfExactType<T>() == null;
    }
  }
  return false;
}

Future<AppHarness> _openWeb1(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final harness = await pumpApp(tester, size: size, servers: twoServers);
  // At 200 % text on a short phone the row starts below the fold, under
  // the coverage chip, the filter and the section header.
  await tester.scrollUntilVisible(
    find.text('web-1'),
    48,
    scrollable: find
        .descendant(
          of: find.byType(FleetServerList),
          matching: find.byType(Scrollable),
        )
        .last,
  );
  await tester.ensureVisible(find.text('web-1'));
  await tester.pumpAndSettle();
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

    // The shell band carries the name; the header does not repeat it.
    expect(
      tester.widget<Text>(find.byKey(DesktopShell.serverTitleKey)).data,
      'web-1',
    );
    expect(_inHeader(find.text('web-1')), findsNothing);
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

  group('a failed link says why (03 §5.3, §10.1)', () {
    test('every failure kind has its words', () {
      expect(failureTexts.keys.toSet(), LinkFailureKind.values.toSet());
    });

    for (final MapEntry(key: failure, value: text) in failureTexts.entries) {
      testWidgets('${failure.name}, under the facts', (tester) async {
        final harness = await _openWeb1(tester, const Size(1280, 800));
        harness.engine.emit(
          LinkState(
            'srv-1',
            LinkClosed(LinkClosedReason.connectFailed, failure: failure),
          ),
        );
        await tester.pumpAndSettle();

        expect(_inHeader(find.text('Failed')), findsOneWidget);
        expect(_inHeader(find.text(text)), findsOneWidget);
        expect(_inHeader(find.byIcon(Icons.info_outline)), findsOneWidget);
        // Read as one node with its icon.
        expect(find.bySemanticsLabel(text), findsOneWidget);
      });
    }

    testWidgets('and nothing else does', (tester) async {
      final harness = await _openWeb1(tester, const Size(1280, 800));
      Finder message() => _inHeader(find.byIcon(Icons.info_outline));
      expect(message(), findsNothing);

      for (final status in const <LinkStatus>[
        LinkReady(),
        // Unclassified, and the owner's close.
        LinkClosed(LinkClosedReason.connectFailed),
        LinkClosed(LinkClosedReason.closedByOwner),
        LinkClosed(LinkClosedReason.linkLost),
        LinkBlocked(LinkBlockedReason.hostKeyChanged),
      ]) {
        harness.engine.emit(LinkState('srv-1', status));
        await tester.pumpAndSettle();
        expect(message(), findsNothing, reason: '$status');
      }

      // A failure goes once the link moves on, as to its backoff.
      harness.engine.emit(
        const LinkState(
          'srv-1',
          LinkClosed(
            LinkClosedReason.connectFailed,
            failure: LinkFailureKind.unreachable,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(message(), findsOneWidget);
      harness.engine.emit(
        LinkState('srv-1', LinkBackoff(DateTime.utc(2026, 10, 16, 12))),
      );
      await tester.pumpAndSettle();
      expect(message(), findsNothing);
    });

    testWidgets('the selected server\'s, not another\'s', (tester) async {
      final harness = await _openWeb1(tester, const Size(1280, 800));
      harness.engine.emit(
        const LinkState(
          'srv-2',
          LinkClosed(
            LinkClosedReason.connectFailed,
            failure: LinkFailureKind.authenticationRejected,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_inHeader(find.byIcon(Icons.info_outline)), findsNothing);
    });

    for (final (name, size) in [
      ('desktop', const Size(960, 700)),
      ('phone', const Size(390, 800)),
    ]) {
      testWidgets('the longest wraps in the $name header at 200 % text', (
        tester,
      ) async {
        final harness = await _openWeb1(tester, size, textScale: 2);
        harness.engine.emit(
          const LinkState(
            'srv-1',
            LinkClosed(
              LinkClosedReason.connectFailed,
              failure: LinkFailureKind.keyPassphraseRequired,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          _inHeader(
            find.text(failureTexts[LinkFailureKind.keyPassphraseRequired]!),
          ),
          findsOneWidget,
        );
      });
    }
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
      // The app bar (phone) and the shell band (desktops) carry the name;
      // the header does not repeat it.
      expect(_inHeader(find.text('web-1')), findsNothing);
      if (name != 'phone') {
        expect(
          tester.widget<Text>(find.byKey(DesktopShell.serverTitleKey)).data,
          'web-1',
        );
      }
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

  // A narrow desktop window at 200 % text: the rail leaves the workspace
  // 398 px, where the header wraps to over 500 px. 960 x 500 also
  // overflows the fleet rail's own column (fleet_rows.dart), which no
  // window this short avoids at this text size and which is not the
  // workspace's concern, so only errors raised inside the workspace count.
  for (final height in const [600.0, 500.0]) {
    testWidgets('a 960 x ${height.round()} desktop window keeps most of the '
        'workspace for the panel at 200 % text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final reportError = FlutterError.onError!;
      FlutterError.onError = (details) {
        if (!_raisedOutside<ServerWorkspace>(details)) reportError(details);
      };
      try {
        final harness = await pumpApp(
          tester,
          size: Size(960, height),
          servers: twoServers,
        );
        // At this size the server's row sits under the rail's fold, so
        // the selection comes from the controller rather than a tap.
        harness.fleet.select('srv-1');
        harness.engine
          ..emit(const LinkState('srv-1', LinkReady()))
          ..emit(HostProfileChanged('srv-1', _twoEngines));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // The header takes at most 40 %; the tab strip and the panel
        // under it keep the rest.
        final workspace = tester.getRect(find.byType(ServerWorkspace));
        final strip = tester.getRect(find.byType(TabBar));
        final panel = tester.getRect(find.byType(SelectedTabView));
        expect(
          panel.bottom - strip.top,
          greaterThanOrEqualTo(workspace.height * 0.6 - 0.5),
        );
        expect(panel.bottom, lessThanOrEqualTo(workspace.bottom + 0.5));

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
      } finally {
        FlutterError.onError = reportError;
      }
    });
  }
}
