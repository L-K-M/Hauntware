import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart' show contrastRatio;
import 'package:klabautermann_app/controllers/coverage_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/coverage.dart';
import 'package:klabautermann_app/ui/fleet_rail.dart' show FleetEmptyState;
import 'package:klabautermann_app/ui/server_workspace.dart';
import 'package:klabautermann_app/ui/sidebar_kit.dart' show SidebarFilterField;
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart' show chartTheme;
import 'support/harness.dart';

const _desktop = Size(1280, 800);
const _phone = Size(390, 800);

const _cardTitle = 'How Klabautermann watches your servers';
const _chipOfTwo = 'Watching 0 of 2 servers on this device, only while open';
const _fleetEmptyBody = 'Add a server to start monitoring your fleet.';
const _workspaceEmptyBody =
    'Choose a server from the fleet to see its workspace.';

final _chip = find.byType(FleetCoverageChip);
final _card = find.byType(FirstRunCoverageCard);
final _sheet = find.byType(CoverageSheet);

/// A controller on its first launch, recording each save.
CoverageController _firstLaunch(List<String> saves, {Object? failWith}) =>
    CoverageController(
      saveDismissal: () async {
        saves.add('dismissed');
        if (failWith != null) throw failWith;
      },
    );

/// What [body] hands to debugPrint. The binding checks that debugPrint is
/// restored before tear-downs run, so this restores it itself.
Future<List<String>> _printedDuring(Future<void> Function() body) async {
  final printed = <String>[];
  final previous = debugPrint;
  debugPrint = (message, {wrapWidth}) => printed.add('$message');
  try {
    await body();
  } finally {
    debugPrint = previous;
  }
  return printed;
}

/// The toast's timer has to run out before the test ends.
Future<void> _letToastsGo(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

void main() {
  group('the fleet coverage (03 §9.5 item 2)', () {
    test('counts the fleet and the monitor set\'s servers in it', () {
      final coverage = FleetCoverage.of(
        twoServers,
        monitorSet: {'srv-2', 'gone'},
      );

      expect(coverage.serverCount, 2);
      expect(coverage.watchedCount, 1);
      expect(FleetCoverage.of(twoServers).watchedCount, 0);
    });

    test('the watched body claims no unwatched servers, since the monitor '
        'set may hold the whole fleet', () {
      final l10n = lookupAppLocalizations(const Locale('en'));

      expect(
        l10n.coverageWatchedBody(1),
        '1 server is read continuously while Klabautermann is open. Any '
        'others are read only while you have them open.',
      );
      expect(
        l10n.coverageWatchedBody(2),
        '2 servers are read continuously while Klabautermann is open. Any '
        'others are read only while you have them open.',
      );
    });
  });

  group('the first-run card (03 §9.5 item 1)', () {
    test('a second dismissal saves and notifies nothing', () async {
      final saves = <String>[];
      final coverage = _firstLaunch(saves);
      addTearDown(coverage.dispose);
      var heard = 0;
      coverage.addListener(() => heard++);

      await coverage.dismissFirstRunCard();
      await coverage.dismissFirstRunCard();

      expect(heard, 1);
      expect(saves, ['dismissed']);
    });

    testWidgets('heads the desktop workspace until dismissed, and the '
        'workspace keeps its state', (tester) async {
      final saves = <String>[];
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: twoServers,
        coverage: _firstLaunch(saves),
      );
      expect(find.text(_cardTitle), findsOneWidget);
      expect(
        find.text(
          'Klabautermann connects over SSH only while it is open. It '
          'installs nothing on your servers unless you ask it to. Charts '
          'cover only the time this device was connected.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('web-1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Logs'));
      await tester.pumpAndSettle();
      final sentBefore = harness.engine.sent.length;

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(_card, findsNothing);
      expect(saves, ['dismissed']);
      expect(
        DefaultTabController.of(tester.element(find.text('Logs'))).index,
        3,
        reason: 'the workspace was not rebuilt from scratch',
      );
      expect(
        harness.engine.sent.skip(sentBefore),
        isEmpty,
        reason: 'no reconnect and no resubscribe',
      );
    });

    testWidgets('a dismissal that cannot be saved says it will return, and '
        'logs why', (tester) async {
      const error = DeviceSettingsReadOnlyException(
        DeviceSettingsIssueKind.newerVersion,
      );
      final saves = <String>[];
      await pumpApp(
        tester,
        size: _desktop,
        coverage: _firstLaunch(saves, failWith: error),
      );

      final printed = await _printedDuring(() async {
        await tester.tap(find.text('Got it'));
        await tester.pumpAndSettle();
      });

      expect(_card, findsNothing);
      expect(printed, contains('$error'));
      expect(
        find.text(
          'Klabautermann could not save that you dismissed the coverage '
          'note, so it shows again after a restart.',
        ),
        findsOneWidget,
      );
      await _letToastsGo(tester);
    });

    testWidgets('heads the phone fleet list over the chip, and at twice the '
        'text size its words scroll and its buttons stay in view, stacked '
        'apart', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final saves = <String>[];
      await pumpApp(
        tester,
        size: const Size(360, 640),
        servers: twoServers,
        coverage: _firstLaunch(saves),
      );

      expect(tester.takeException(), isNull);
      final card = tester.getRect(_card);
      expect(card.height, lessThanOrEqualTo(640 / 2));
      expect(
        find.descendant(of: _card, matching: find.byType(Scrollable)),
        findsOneWidget,
      );
      expect(card.contains(tester.getBottomRight(find.text('Got it'))), isTrue);
      final details = tester.getRect(
        find.widgetWithText(TextButton, 'Coverage details'),
      );
      final dismiss = tester.getRect(find.widgetWithText(TextButton, 'Got it'));
      expect(dismiss.top, greaterThanOrEqualTo(details.bottom));
      expect(dismiss.top - details.bottom, 8);
      expect(card.bottom, lessThan(tester.getTopLeft(_chip).dy));
      // At this size the list starts below the fold, with its filter.
      expect(
        tester.getBottomLeft(_chip).dy,
        lessThanOrEqualTo(
          tester.getTopLeft(find.byType(SidebarFilterField)).dy,
        ),
      );

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(saves, ['dismissed']);
      expect(_chip, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('over a phone\'s empty fleet at twice the text size, the '
        'empty state scrolls under the card, and is centred once it fits', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      // A small phone's system bars; the fleet is empty until enrollment.
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
      await pumpApp(
        tester,
        size: const Size(360, 640),
        coverage: _firstLaunch([]),
      );

      expect(tester.takeException(), isNull);
      expect(_card, findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(_fleetEmptyBody),
        50,
        scrollable: find.descendant(
          of: find.byType(FleetEmptyState),
          matching: find.byType(Scrollable),
        ),
      );

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      final region = tester.getRect(find.byType(FleetEmptyState));
      final content = tester
          .getRect(find.byIcon(Icons.dns_outlined))
          .expandToInclude(tester.getRect(find.text(_fleetEmptyBody)));
      expect(content.center.dy, moreOrLessEquals(region.center.dy));
    });

    testWidgets('at twice the text size in a short desktop window, the '
        'workspace\'s empty state scrolls under the card, and is centred '
        'once it fits', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpApp(
        tester,
        size: const Size(960, 600),
        servers: twoServers,
        coverage: _firstLaunch([]),
      );

      expect(tester.takeException(), isNull);
      expect(_card, findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(_workspaceEmptyBody),
        50,
        scrollable: find.descendant(
          of: find.byType(ServerWorkspace),
          matching: find.byType(Scrollable),
        ),
      );

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      final region = tester.getRect(find.byType(ServerWorkspace));
      final content = tester
          .getRect(find.text('Select a server'))
          .expandToInclude(tester.getRect(find.text(_workspaceEmptyBody)));
      expect(content.center.dy, moreOrLessEquals(region.center.dy));
    });
  });

  for (final brightness in Brightness.values) {
    test('the coverage surfaces keep 4.5:1 text contrast '
        '(${brightness.name}, 10.10)', () {
      final scheme = chartTheme(brightness).colorScheme;
      final pairs = {
        'chip label': (scheme.onSecondaryContainer, scheme.secondaryContainer),
        'card text': (scheme.onSurface, scheme.surfaceContainerLow),
        'card buttons': (scheme.primary, scheme.surfaceContainerLow),
        'sheet bodies': (scheme.onSurfaceVariant, scheme.surfaceContainerHigh),
        'tier badge': (scheme.primary, scheme.surfaceContainerHigh),
      };
      for (final MapEntry(key: name, value: (fore, back)) in pairs.entries) {
        expect(
          contrastRatio(fore, back),
          greaterThanOrEqualTo(4.5),
          reason: name,
        );
      }
    });
  }

  group('the coverage chip and sheet (03 §9.5 item 2)', () {
    testWidgets('the rail\'s chip counts the fleet and opens the sheet as a '
        'dialog', (tester) async {
      await pumpApp(tester, size: _desktop, servers: twoServers);

      expect(find.text(_chipOfTwo), findsOneWidget);
      expect(
        tester.getBottomLeft(_chip).dy,
        tester.getTopLeft(find.byType(SidebarFilterField)).dy,
        reason:
            'the chip heads the rail, over the filter and the fleet\'s '
            'sections',
      );
      await tester.tap(_chip);
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Coverage on this device'), findsOneWidget);
      expect(find.text('T0'), findsOneWidget);
      expect(find.text('SSH while Klabautermann is open'), findsOneWidget);
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      for (final item in [
        'Covered',
        'Live readings while open',
        'Not covered',
        'Continuous watching',
        'No server is watched on this device, so each is read only while '
            'you have it open.',
        'While Klabautermann is closed',
        'A server going down',
        'History before you connected',
      ]) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
      expect(
        top('Continuous watching'),
        greaterThan(top('Not covered')),
        reason: 'no server is watched, so watching is not covered',
      );
      expect(
        find.text('While in the background'),
        findsNothing,
        reason: 'desktops keep sampling in the background',
      );

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('the chip is one button for screen readers and the keyboard', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpApp(tester, size: _desktop, servers: twoServers);

      expect(
        tester.getSemantics(find.bySemanticsLabel(_chipOfTwo)),
        matchesSemantics(
          label: _chipOfTwo,
          onTapHint: 'Show coverage details',
          isButton: true,
          hasTapAction: true,
          isFocusable: true,
          hasFocusAction: true,
        ),
      );

      // The chip's own focus node, as a Tab stop would give it focus.
      Focus.of(tester.element(find.text(_chipOfTwo))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_sheet, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
      semantics.dispose();
    });

    testWidgets('opens without motion when the platform asks for none '
        '(A11Y-11)', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      for (final size in [_desktop, _phone]) {
        await pumpApp(tester, size: size, servers: twoServers);

        await tester.tap(_chip);
        await tester.pump();

        final route = ModalRoute.of(tester.element(_sheet))!;
        expect(route.animation!.status, AnimationStatus.completed);
        Navigator.of(tester.element(_sheet)).pop();
        await tester.pump();
        expect(_sheet, findsNothing, reason: '$size');
      }
    });

    testWidgets('an empty fleet shows no chip', (tester) async {
      final harness = await pumpApp(tester, size: _desktop);
      expect(_chip, findsOneWidget);
      expect(find.textContaining('Watching'), findsNothing);

      harness.engine.emit(
        CatalogReplaced([
          FleetEntry(
            serverId: 'srv-1',
            label: 'web-1',
            host: 'web-1.example',
            port: kSshDefaultPort,
            origin: FleetEntryOrigin.sshConfig,
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Watching 0 of 1 server on this device, only while open'),
        findsOneWidget,
      );
    });

    testWidgets(
      'on a phone the sheet rises from the bottom and says that '
      'reading stops in the background',
      (tester) async {
        await pumpApp(tester, size: _phone, servers: twoServers);

        await tester.tap(_chip);
        await tester.pumpAndSettle();

        expect(find.byType(BottomSheet), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('While in the background'),
          100,
          scrollable: find.descendant(
            of: _sheet,
            matching: find.byType(Scrollable),
          ),
        );
        expect(
          find.text(
            'Reading stops while Klabautermann is in the background and '
            'resumes when you return.',
          ),
          findsOneWidget,
        );
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  });
}
