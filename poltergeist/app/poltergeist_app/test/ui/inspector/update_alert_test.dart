import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_apk_update/ghost_apk_update.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/update_check_controller.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_app_transfer_queue.dart';
import '../../support/scripted_apk_updater.dart';

/// The update alert in the real shell's Alerts tab: a link to the release
/// page everywhere, and on Android the in-place update's Update, progress
/// with Cancel, Install and Retry rows.
void main() {
  late FakeAppTransferQueue queue;

  setUp(() => queue = FakeAppTransferQueue());
  tearDown(() => queue.close());

  Future<UpdateCheckController> pumpShell(
    WidgetTester tester, {
    ApkUpdater? updater,
  }) async {
    final updates = UpdateCheckController(
      checker: UpdateChecker(
        repo: poltergeistUpdateRepo,
        client: http_testing.MockClient(
          (_) async =>
              http.Response(jsonEncode(releaseWithApk('v1.10.0')), 200),
        ),
      ),
      apkUpdater: updater,
    );
    addTearDown(updates.dispose);
    await tester.runAsync(() => updates.checkForUpdate('1.9.0'));

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        // Android formats sizes in decimal units.
        theme: ThemeData(platform: TargetPlatform.android),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(
          transferQueue: queue,
          updateCheck: updates,
          restoredSession: const SessionState(
            activePaneId: 'pane.left',
            secondPaneHidden: false,
            activityPanelHidden: true,
            inspectorHidden: false,
            inspectorTab: 'alerts',
            panes: [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return updates;
  }

  testWidgets('without an updater the alert links to the release page', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(find.text('Poltergeist 1.10.0 is available'), findsOneWidget);
    expect(find.text('View Release'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
  });

  testWidgets('Update downloads the APK; progress offers Cancel', (
    tester,
  ) async {
    final updater = ScriptedApkUpdater();
    await pumpShell(tester, updater: updater);

    expect(find.text('104 MB download'), findsOneWidget);
    expect(find.text('View Release'), findsNothing);
    await tester.tap(find.text('Update'));
    await tester.pump();
    expect(updater.requested, [apkOf('v1.10.0')]);

    updater.scripted = const ApkUpdateDownloading(26000000, 103670866);
    await tester.pump();
    expect(find.text('Downloading Poltergeist 1.10.0…'), findsOneWidget);
    expect(find.text('26 MB of 104 MB'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    expect(updater.cancels, 1);
  });

  testWidgets('a backed-out installer reopens with Install', (tester) async {
    final updater = ScriptedApkUpdater();
    await pumpShell(tester, updater: updater);

    updater.scripted = const ApkUpdateReady();
    await tester.pump();

    expect(find.text('Poltergeist 1.10.0 is ready to install'), findsOneWidget);
    await tester.tap(find.text('Install'));
    expect(updater.requested, hasLength(1));
  });

  testWidgets('a failure says why and offers Retry', (tester) async {
    final updater = ScriptedApkUpdater();
    await pumpShell(tester, updater: updater);

    updater.scripted = const ApkUpdateFailed(ApkUpdateFailure.verification);
    await tester.pump();

    expect(
      find.text('Poltergeist 1.10.0 could not be installed'),
      findsOneWidget,
    );
    expect(
      find.text('The download did not match the release and was discarded.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    expect(updater.requested, hasLength(1));
  });

  testWidgets('dismissing the alert stops a running download', (tester) async {
    final updater = ScriptedApkUpdater();
    await pumpShell(tester, updater: updater);
    updater.scripted = const ApkUpdateDownloading(1, 2);
    await tester.pump();

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();

    expect(updater.cancels, 1);
    expect(find.textContaining('Poltergeist 1.10.0'), findsNothing);
  });
}
