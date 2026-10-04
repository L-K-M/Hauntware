import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/server_state_indicator.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'contrast_math.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

const _blocked = ServerStatus(
  ServerConnectionState.blocked,
  detail: 'Host key changed for web.example.com:22.',
);

const _failedConnect = ServerStatus(
  ServerConnectionState.disconnected,
  detail: 'Authentication failed for deploy@web.example.com:22.',
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPoltergeistTheme(brightness),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('the composed indicator mapping', () {
    ServerIndicatorGlyph glyphOf({ServerStatus? status, ProbeStatus? probe}) {
      return serverIndicatorOf(_l10n, status: status, probe: probe).glyph;
    }

    test('no truth paints nothing', () {
      final appearance = serverIndicatorOf(_l10n);

      expect(appearance.glyph, ServerIndicatorGlyph.none);
      expect(appearance.label, isEmpty);
    });

    test('probe truth alone renders the tri-state dot', () {
      for (final (probe, label) in [
        (ProbeStatus.online, _l10n.probeStatusOnline),
        (ProbeStatus.offline, _l10n.probeStatusOffline),
        (ProbeStatus.unknown, _l10n.probeStatusUnknown),
      ]) {
        final appearance = serverIndicatorOf(_l10n, probe: probe);

        expect(appearance.glyph, ServerIndicatorGlyph.probe, reason: '$probe');
        expect(appearance.label, label);
      }
    });

    test('each connection state maps to one glyph and label', () {
      for (final (status, glyph, label) in [
        (
          const ServerStatus(ServerConnectionState.connecting),
          ServerIndicatorGlyph.pending,
          _l10n.connectionStateConnecting,
        ),
        (
          const ServerStatus(ServerConnectionState.reconnecting),
          ServerIndicatorGlyph.pending,
          _l10n.connectionStateReconnecting,
        ),
        (
          const ServerStatus(ServerConnectionState.connected),
          ServerIndicatorGlyph.connected,
          _l10n.connectionStateConnected,
        ),
        (
          const ServerStatus(ServerConnectionState.disconnected),
          ServerIndicatorGlyph.idle,
          _l10n.connectionStateNotConnected,
        ),
        (
          _failedConnect,
          ServerIndicatorGlyph.failed,
          _l10n.connectionFailedTitle,
        ),
        (_blocked, ServerIndicatorGlyph.blocked, _l10n.connectionBlockedTitle),
      ]) {
        final appearance = serverIndicatorOf(_l10n, status: status);

        expect(appearance.glyph, glyph, reason: status.state.name);
        expect(appearance.label, label, reason: status.state.name);
      }
    });

    test('a block outranks a reachable probe', () {
      // The audit finding: a green "reachable" dot rendered next to a
      // blocked panel. Live truth outranks probes (02 §4).
      expect(
        glyphOf(status: _blocked, probe: ProbeStatus.online),
        ServerIndicatorGlyph.blocked,
      );
    });

    test('a failure the state explains outranks a reachable probe', () {
      expect(
        glyphOf(status: _failedConnect, probe: ProbeStatus.online),
        ServerIndicatorGlyph.failed,
      );
    });

    test('a connected server outranks an offline probe', () {
      // The reverse contradiction of the audit finding: authenticated
      // transports prove reachability, so a stale offline result cannot
      // paint beside a session the user is actively using (02 §4).
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.connected),
          probe: ProbeStatus.offline,
        ),
        ServerIndicatorGlyph.connected,
      );
    });

    test('a connected server outranks an unknown probe', () {
      // "Unknown" reachability beside an authenticated transport is the
      // same contradiction: the transport proves reachability, so the
      // glyph answers instead of the grey dot.
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.connected),
          probe: ProbeStatus.unknown,
        ),
        ServerIndicatorGlyph.connected,
      );
    });

    test('a truth that does not contradict leaves the probe dot', () {
      // 02 §4 gives the favorite row its tri-state probe dot, and 07 §3.3
      // requires it to render in the interim list: a healthy or pending
      // connection does not contradict a reachability result.
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.connected),
          probe: ProbeStatus.online,
        ),
        ServerIndicatorGlyph.probe,
      );
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.connecting),
          probe: ProbeStatus.offline,
        ),
        ServerIndicatorGlyph.probe,
      );
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.disconnected),
          probe: ProbeStatus.unknown,
        ),
        ServerIndicatorGlyph.probe,
      );
    });

    test('connection truth renders when no probe result exists', () {
      expect(
        glyphOf(status: const ServerStatus(ServerConnectionState.connected)),
        ServerIndicatorGlyph.connected,
      );
    });
  });

  group('ServerStateGlyph paints', () {
    Finder inGlyph(Finder matching) =>
        find.descendant(of: find.byType(ServerStateGlyph), matching: matching);

    testWidgets('every glyph sits in the shared 24 px box', (tester) async {
      for (final glyph in [
        ServerIndicatorGlyph.none,
        ServerIndicatorGlyph.pending,
        ServerIndicatorGlyph.connected,
        ServerIndicatorGlyph.idle,
        ServerIndicatorGlyph.failed,
        ServerIndicatorGlyph.blocked,
      ]) {
        await _pump(tester, ServerStateGlyph(glyph));
        expect(
          tester.getSize(find.byType(ServerStateGlyph)),
          const Size(24, 24),
          reason: glyph.name,
        );
        // A fresh tree per glyph: the pending spinner never settles.
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('dots are 10 px circles in the theme status colours', (
      tester,
    ) async {
      for (final (glyph, colorOf)
          in <(ServerIndicatorGlyph, Color Function(PoltergeistChrome))>[
            (ServerIndicatorGlyph.connected, (c) => c.statusConnected),
            (ServerIndicatorGlyph.failed, (c) => c.statusFailed),
            (ServerIndicatorGlyph.idle, (c) => c.statusUnknown),
          ]) {
        await _pump(tester, ServerStateGlyph(glyph));
        final chrome = PoltergeistChrome.of(
          tester.element(find.byType(ServerStateGlyph)),
        );
        final dot = inGlyph(find.byType(Container));
        expect(tester.getSize(dot), const Size(10, 10), reason: glyph.name);
        final decoration =
            tester.widget<Container>(dot).decoration! as BoxDecoration;
        expect(decoration.shape, BoxShape.circle, reason: glyph.name);
        expect(decoration.color, colorOf(chrome), reason: glyph.name);
        expect(inGlyph(find.byType(Icon)), findsNothing, reason: glyph.name);
      }
    });

    testWidgets('blocked paints the 14 px shield in the failure colour', (
      tester,
    ) async {
      await _pump(tester, const ServerStateGlyph(ServerIndicatorGlyph.blocked));
      final chrome = PoltergeistChrome.of(
        tester.element(find.byType(ServerStateGlyph)),
      );

      final icon = tester.widget<Icon>(inGlyph(find.byType(Icon)));
      expect(icon.icon, Icons.gpp_bad);
      expect(icon.size, 14);
      expect(icon.color, chrome.statusFailed);
      expect(inGlyph(find.byType(CircularProgressIndicator)), findsNothing);
    });

    testWidgets('pending spins at 14 px in the primary colour', (tester) async {
      await _pump(tester, const ServerStateGlyph(ServerIndicatorGlyph.pending));
      final scheme = Theme.of(
        tester.element(find.byType(ServerStateGlyph)),
      ).colorScheme;

      final spinner = inGlyph(find.byType(CircularProgressIndicator));
      expect(spinner, findsOneWidget);
      expect(tester.getSize(spinner), const Size(14, 14));
      expect(
        tester.widget<CircularProgressIndicator>(spinner).color,
        scheme.primary,
      );
      expect(inGlyph(find.byType(Icon)), findsNothing);
    });

    testWidgets('none paints nothing inside its box', (tester) async {
      await _pump(tester, const ServerStateGlyph(ServerIndicatorGlyph.none));

      expect(inGlyph(find.byType(Container)), findsNothing);
      expect(inGlyph(find.byType(Icon)), findsNothing);
      expect(inGlyph(find.byType(CircularProgressIndicator)), findsNothing);
    });

    testWidgets('each dot paints its exact colour on screen', (tester) async {
      // Pins the rendered pixels, not just the decoration: a golden-capture
      // color-space artifact must never hide a real paint regression.
      // Deliberately exact (no ±1 tolerance): an SDK color-pipeline change
      // SHOULD fail this pin and be triaged as such, not absorbed silently.
      for (final glyph in [
        ServerIndicatorGlyph.connected,
        ServerIndicatorGlyph.failed,
        ServerIndicatorGlyph.idle,
      ]) {
        for (final brightness in Brightness.values) {
          await _pump(
            tester,
            RepaintBoundary(
              key: const ValueKey('dot-boundary'),
              child: SizedBox(
                width: 40,
                height: 40,
                child: ServerStateGlyph(glyph),
              ),
            ),
            brightness: brightness,
          );

          // The dot is centred in the box, so the box centre is the dot
          // centre. toImage needs a real event loop; runAsync provides one
          // inside the test zone.
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('dot-boundary')),
          );
          final pixel = (await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 3);
            try {
              final data = await image.toByteData();
              final width = image.width;
              final center = (width ~/ 2) * width + width ~/ 2;
              // Honor the view's offset: a view-backed ByteData must sample
              // from its own start, never the underlying buffer's zero.
              return data!.buffer.asUint8List(
                data.offsetInBytes + center * 4,
                4,
              );
            } finally {
              image.dispose();
            }
          }))!;
          final context = tester.element(find.byType(ServerStateGlyph));
          final scheme = Theme.of(context).colorScheme;
          final expected = switch (glyph) {
            ServerIndicatorGlyph.connected => PoltergeistChrome.of(
              context,
            ).statusConnected,
            ServerIndicatorGlyph.failed => scheme.error,
            _ => scheme.outline,
          };
          final name = '${glyph.name} (${brightness.name})';

          expect(pixel[0], (expected.r * 255).round(), reason: 'red of $name');
          expect(
            pixel[1],
            (expected.g * 255).round(),
            reason: 'green of $name',
          );
          expect(pixel[2], (expected.b * 255).round(), reason: 'blue of $name');
          expect(pixel[3], 255, reason: 'alpha of $name');
          // A fresh tree per iteration keeps the captured picture current.
          await tester.pumpWidget(const SizedBox());
        }
      }
    });
  });

  test('indicator colors stay above 3:1 on both theme surfaces', () {
    // Every color the composed indicator can paint keeps 02 §4's contrast
    // floor (SEA-019). The sidebar's probe offline/unknown dots reuse the
    // scheme colors pinned below (`error`/`outline`). The backgrounds are
    // the resting surface and its scrolled-under tint.
    for (final brightness in Brightness.values) {
      final scheme = buildPoltergeistTheme(brightness).colorScheme;
      final scrolled = ElevationOverlay.applySurfaceTint(
        scheme.surface,
        scheme.surfaceTint,
        3,
      );
      // D32's chrome surfaces the indicator sits on (sidebar rows, the
      // header's location title, the inspector).
      final chrome = buildPoltergeistTheme(
        brightness,
      ).extension<PoltergeistChrome>()!;

      for (final (name, color) in <(String, Color)>[
        ('connected', chrome.statusConnected),
        ('failed', scheme.error),
        ('blocked', scheme.error),
        ('idle', scheme.outline),
        ('pending', scheme.primary),
      ]) {
        for (final background in <(String, Color)>[
          ('surface', scheme.surface),
          ('scrolled-under', scrolled),
          ('sidebar', chrome.sidebarBackground),
          ('header', chrome.headerBackground),
          ('inspector', chrome.inspectorBackground),
        ]) {
          expect(
            contrast(color, background.$2),
            greaterThanOrEqualTo(minimumNonTextContrast),
            reason: '$name on ${background.$1} (${brightness.name})',
          );
        }
      }
    }
  });
}
