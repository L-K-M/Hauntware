import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/services/macos_titlebar.dart';
import 'package:klabautermann_app/ui/coverage.dart' show FleetCoverageChip;
import 'package:klabautermann_app/ui/desktop_shell.dart';
import 'package:klabautermann_app/ui/fleet_rail.dart';
import 'package:klabautermann_app/ui/inspector_pane.dart';
import 'package:klabautermann_app/ui/macos_toolbar_band.dart';
import 'package:klabautermann_app/ui/server_workspace.dart';
import 'package:klabautermann_app/ui/sidebar_kit.dart' show SidebarFilterField;

import 'support/harness.dart';

/// The macOS integrated titlebar (03 §10.2): the install and its fallback,
/// the band's state over `klabautermann/window`, and a layout that keeps
/// every pane's content below the band the traffic lights sit in.
void main() {
  const channel = MethodChannel(windowChannelName);

  void answerBandQuery(Object? Function(MethodCall call) answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => answer(call));
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }

  group('installing the titlebar', () {
    test('uses the channel name the identities fix', () {
      expect(windowChannelName, 'klabautermann/window');
    });

    testWidgets('returns the band and asks the runner for its state', (
      tester,
    ) async {
      final calls = <String>[];
      answerBandQuery((call) {
        calls.add(call.method);
        return false;
      });
      final adapter = _FakeTitlebar();

      final band = await installMacosTitlebar(adapter: adapter);
      addTearDown(() => band?.dispose());

      expect(adapter.calls, ['install']);
      expect(band, isNotNull);
      expect(calls, ['isToolbarBandVisible']);
      // A window restored straight into full screen has no band.
      expect(band!.value, isFalse);
    });

    testWidgets('keeps the windowed layout when no runner answers', (
      tester,
    ) async {
      // An empty reply is how a channel without a handler answers.
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler(windowChannelName, (_) async => null);
      addTearDown(
        () => messenger.setMockMessageHandler(windowChannelName, null),
      );

      final band = await installMacosTitlebar(adapter: _FakeTitlebar());
      addTearDown(() => band?.dispose());

      expect(band?.value, isTrue);
    });

    testWidgets('follows the runner into and out of full screen', (
      tester,
    ) async {
      answerBandQuery((_) => true);
      final band = await installMacosTitlebar(adapter: _FakeTitlebar());
      addTearDown(() => band?.dispose());

      Future<void> runnerSays(bool visible) =>
          tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            windowChannelName,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('toolbarBandChanged', visible),
            ),
            (_) {},
          );

      await runnerSays(false);
      expect(band!.value, isFalse);
      await runnerSays(true);
      expect(band.value, isTrue);
    });

    testWidgets('puts the standard titlebar back when the install fails', (
      tester,
    ) async {
      final adapter = _FakeTitlebar()..failInstall = true;

      final band = await installMacosTitlebar(adapter: adapter);

      expect(band, isNull, reason: 'nothing reserves a band');
      expect(adapter.calls, ['install', 'reset']);
    });

    testWidgets('survives a failed reset too', (tester) async {
      final adapter = _FakeTitlebar()
        ..failInstall = true
        ..failReset = true;

      expect(await installMacosTitlebar(adapter: adapter), isNull);
      expect(adapter.calls, ['install', 'reset']);
    });
  });

  group('the layout under the band', () {
    Finder paneFill(Type pane) => find
        .ancestor(of: find.byType(pane), matching: find.byType(ColoredBox))
        .first;

    /// Measured from the shell's top: on Linux and Windows the menu strip
    /// sits above the shell. The panes start under the shell's own
    /// 52 pt band and its divider on every platform (03 §10.2).
    const belowShellBand = macosToolbarBandHeight + 1;
    void expectPanesBelow(WidgetTester tester, double top) {
      final shell = tester.getTopLeft(find.byType(DesktopShell)).dy;
      for (final pane in [FleetRail, ServerWorkspace, InspectorPane]) {
        expect(
          tester.getTopLeft(find.byType(pane)).dy - shell,
          top,
          reason: '$pane',
        );
      }
    }

    testWidgets('keeps every pane\'s content below the band, with the rail and '
        'inspector colours running up behind the traffic lights', (
      tester,
    ) async {
      final band = ValueNotifier(true);
      addTearDown(band.dispose);
      await pumpApp(tester, servers: twoServers, toolbarBand: band);

      expect(find.byType(DesktopShell), findsOneWidget);
      expectPanesBelow(tester, belowShellBand);
      expect(tester.getTopLeft(paneFill(FleetRail)).dy, 0);
      // The header spans the workspace and the inspector above it, so
      // only the rail's colour runs up behind the traffic lights.
      expect(
        tester.getTopLeft(paneFill(InspectorPane)).dy,
        belowShellBand,
      );
      // The rail's list does not pad for the band a second time: the
      // filter above its sections starts right under the coverage chip.
      expect(
        tester.getTopLeft(find.byType(SidebarFilterField)).dy,
        tester.getBottomLeft(find.byType(FleetCoverageChip)).dy,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('gives the band back in full screen; the shell\'s own band '
        'stays', (tester) async {
      final band = ValueNotifier(true);
      addTearDown(band.dispose);
      await pumpApp(tester, servers: twoServers, toolbarBand: band);

      band.value = false;
      await tester.pumpAndSettle();

      expectPanesBelow(tester, belowShellBand);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('reserves nothing extra when the titlebar was not '
        'installed', (tester) async {
      await pumpApp(tester, servers: twoServers);

      expectPanesBelow(tester, belowShellBand);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('reserves nothing extra off macOS', (tester) async {
      final band = ValueNotifier(true);
      addTearDown(band.dispose);
      await pumpApp(tester, servers: twoServers, toolbarBand: band);

      expectPanesBelow(tester, belowShellBand);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('keeps the narrow layout\'s app bar below the band', (
      tester,
    ) async {
      final band = ValueNotifier(true);
      addTearDown(band.dispose);
      await pumpApp(
        tester,
        size: const Size(500, 800),
        servers: twoServers,
        toolbarBand: band,
      );

      final appBar = find.byType(AppBar);
      expect(tester.getTopLeft(appBar).dy, 0, reason: 'paints into it');
      expect(
        tester.getTopLeft(find.byType(NavigationToolbar)).dy,
        macosToolbarBandHeight,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });
}

final class _FakeTitlebar implements MacosTitlebarAdapter {
  final calls = <String>[];
  bool failInstall = false;
  bool failReset = false;

  @override
  Future<void> install() async {
    calls.add('install');
    if (failInstall) throw StateError('no window utils');
  }

  @override
  Future<void> reset() async {
    calls.add('reset');
    if (failReset) throw StateError('no window utils');
  }
}
