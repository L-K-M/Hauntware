import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/phone_shell.dart';
import 'package:klabautermann_app/ui/server_detail_page.dart';
import 'package:klabautermann_app/ui/settings_page.dart';

import 'support/harness.dart';

/// 03 §10.5: under 600 dp the fleet list is home and a server opens a
/// pushed screen with the bottom bar. Widths between the phone and the
/// 960 px desktop breakpoint share this stack until the tablet two-pane
/// lands (v1).
void main() {
  testWidgets('shows the fleet list as home under 600 dp', (tester) async {
    await pumpApp(tester, size: const Size(390, 800), servers: twoServers);

    expect(find.byType(PhoneShell), findsOneWidget);
    expect(find.text('Fleet'), findsOneWidget);
    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('db-1'), findsOneWidget);
  });

  testWidgets('uses the phone stack between the phone and desktop '
      'breakpoints', (tester) async {
    await pumpApp(tester, size: const Size(700, 900), servers: twoServers);

    expect(find.byType(PhoneShell), findsOneWidget);
  });

  testWidgets('the empty fleet shows its invitation', (tester) async {
    await pumpApp(tester, size: const Size(390, 800));

    expect(find.text('No servers yet'), findsOneWidget);
    expect(find.text('Add a server to start monitoring your fleet.'), findsOne);
  });

  testWidgets('tapping a server pushes the detail page with its bottom bar', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      size: const Size(390, 800),
      servers: twoServers,
    );

    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();

    expect(harness.fleet.selectedServerId, 'srv-1');
    expect(find.byType(ServerDetailPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final label in ['Overview', 'Docker', 'Logs', 'More']) {
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('the detail page follows the server\'s link status in words', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(390, 800), servers: twoServers);

    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnected'), findsOneWidget);
  });

  testWidgets('the settings gear pushes the settings route', (tester) async {
    await pumpApp(tester, size: const Size(390, 800));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
  });
}
