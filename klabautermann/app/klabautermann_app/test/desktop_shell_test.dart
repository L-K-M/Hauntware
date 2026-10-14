import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/desktop_shell.dart';
import 'package:klabautermann_app/ui/fleet_rail.dart';
import 'package:klabautermann_app/ui/inspector_pane.dart';
import 'package:klabautermann_app/ui/server_workspace.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

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

  testWidgets('a server row says its link status in words, not colour alone', (
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

    harness.engine.emit(const LinkState('srv-1', LinkReady()));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Server status: Connected'), findsOneWidget);
    expect(find.bySemanticsLabel('Server status: Disconnected'), findsOne);
  });

  test('every link status has its word (D46)', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    String word(LinkStatus status) => linkStatusWord(l10n, status);

    expect(word(const LinkIdle()), 'Disconnected');
    expect(word(const LinkConnecting()), 'Connecting');
    expect(word(const LinkAuthenticating()), 'Authenticating');
    expect(word(const LinkReady()), 'Connected');
    expect(
      word(const LinkDegraded(LinkDegradedReason.sessionLimitLearned)),
      'Connected with limits',
    );
    expect(word(LinkBackoff(DateTime.utc(2026))), 'Waiting to reconnect');
    expect(
      word(const LinkNeedsUser(promptId: 'p-1', kind: PromptKind.hostKey)),
      'Needs your input',
    );
    expect(
      word(const LinkBlocked(LinkBlockedReason.hostKeyChanged)),
      'Blocked',
    );
    expect(
      word(const LinkClosed(LinkClosedReason.closedByOwner)),
      'Disconnected',
    );
    expect(
      word(
        const LinkClosed(
          LinkClosedReason.connectFailed,
          failure: LinkFailureKind.authenticationRejected,
        ),
      ),
      'Failed',
    );
    for (final reason in [
      LinkClosedReason.linkLost,
      LinkClosedReason.transportError,
      LinkClosedReason.pingTimeout,
    ]) {
      expect(word(LinkClosed(reason)), 'Connection lost', reason: '$reason');
    }
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

  testWidgets('a tablet\'s insets and keyboard reach no pane a second time', (
    tester,
  ) async {
    // A landscape tablet with a cutout, the keyboard up. The shell insets
    // the panes for the cutout and the home indicator and the Scaffold
    // shrinks them for the keyboard, so their own scroll views and safe
    // areas must see none of it, or each pads for it again.
    const insets = FakeViewPadding(left: 30, top: 24, bottom: 20);
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await pumpApp(tester, servers: twoServers);

    expect(find.byType(DesktopShell), findsOneWidget);
    for (final pane in [FleetRail, ServerWorkspace, InspectorPane]) {
      final context = tester.element(find.byType(pane));
      expect(MediaQuery.paddingOf(context), EdgeInsets.zero, reason: '$pane');
      expect(
        MediaQuery.viewInsetsOf(context),
        EdgeInsets.zero,
        reason: '$pane',
      );
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
