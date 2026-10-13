import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/desktop_shell.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show LinkPhase, LinkState;

import 'support/harness.dart';

/// 03 §10.2: the three panes at 960 px and up.
void main() {
  testWidgets('shows rail, workspace and inspector side by side', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1280, 800), servers: twoServers);

    expect(find.byType(DesktopShell), findsOneWidget);
    // The rail caps its section titles visually; semantics keep the
    // authored spelling (asserted below by label).
    expect(find.text('SERVERS'), findsOneWidget);
    expect(find.text('Select a server'), findsOneWidget);
    expect(find.text('Inspector'), findsOneWidget);
  });

  testWidgets('the rail lists servers and selects one into the workspace', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      size: const Size(1280, 800),
      servers: twoServers,
    );

    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('db-1'), findsOneWidget);
    expect(find.text('Select a server'), findsOneWidget);

    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();

    expect(harness.fleet.selectedServerId, 'srv-1');
    // The workspace replaces its empty state with the server's tab strip in
    // 03 §10.2's planned order.
    expect(find.text('Select a server'), findsNothing);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Access'), findsOneWidget);
  });

  testWidgets('the rail shows its empty state without servers', (tester) async {
    await pumpApp(tester, size: const Size(1280, 800));

    expect(find.text('No servers yet'), findsOneWidget);
    expect(find.text('Add a server to start monitoring your fleet.'), findsOne);
  });

  testWidgets('a server row states its link phase in words, not colour alone', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      size: const Size(1280, 800),
      servers: twoServers,
    );

    // Nothing observed yet: the row still carries the word (03 §10.3).
    expect(
      find.bySemanticsLabel('Server status: Disconnected'),
      findsNWidgets(2),
    );

    harness.engine.emit(const LinkState('srv-1', LinkPhase.connected));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Server status: Connected'), findsOneWidget);
    expect(find.bySemanticsLabel('Server status: Disconnected'), findsOne);
  });

  testWidgets('the bottom bar and section header carry semantics labels', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1280, 800), servers: twoServers);

    expect(find.bySemanticsLabel('Servers, 2 servers'), findsOneWidget);
    expect(
      find.byTooltip('Settings'),
      findsOneWidget,
      reason: 'the rail\'s gear must be reachable by name (03 §10.10)',
    );
    expect(find.byTooltip('Add'), findsOneWidget);
  });

  testWidgets('collapsing the section hides the rows but keeps the rail', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1280, 800), servers: twoServers);

    await tester.tap(find.byTooltip('Hide section'));
    await tester.pumpAndSettle();

    expect(find.text('web-1'), findsNothing);
    expect(find.byTooltip('Show section'), findsOneWidget);
    expect(find.text('Inspector'), findsOneWidget);
  });
}
