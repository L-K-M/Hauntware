// The update banner's session states (c3 §shells, D19/D23): the newer
// release the launch check found, the action that resolves it, and the
// download's progress on Android.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_apk_update/ghost_apk_update.dart';
import 'package:ghost_update/ghost_update.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/server_coverage.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/scripted_apk_updater.dart';

void main() {
  Map<String, Object?> releaseJson(String tag) => {
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
    'assets': [
      {
        'name': klabautermannAndroidReleaseAsset,
        'browser_download_url':
            'https://github.com/L-K-M/Hauntware/releases/download/$tag/'
            '$klabautermannAndroidReleaseAsset',
        'size': 103670866,
        'digest':
            'sha256:'
            '0be7459344d614eb920cce957e33c6d272a1a4540b291b16a580cee7adac64f3',
      },
    ],
  };

  UpdateCheckController controllerWith({
    ScriptedApkUpdater? updater,
    String tag = 'v9.9.9',
  }) => UpdateCheckController(
    checker: UpdateChecker(
      repo: klabautermannUpdateRepo,
      userAgent: klabautermannUpdateUserAgent,
      client: http_testing.MockClient(
        (request) async => http.Response(jsonEncode(releaseJson(tag)), 200),
      ),
    ),
    apkUpdater: updater,
    androidReleaseAsset: klabautermannAndroidReleaseAsset,
  );

  Future<void> pump(
    WidgetTester tester,
    UpdateCheckController updates, {
    Future<void> Function(Uri url)? openRelease,
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: UpdateNoticeBanner(
          updates: updates,
          openRelease: openRelease ?? (Uri _) async {},
        ),
      ),
    ),
  );

  testWidgets('nothing shows while there is no newer release', (tester) async {
    final updates = controllerWith();
    await pump(tester, updates);

    expect(find.text('Klabautermann 9.9.9 is available'), findsNothing);
  });

  testWidgets('off Android the banner links to the release page', (
    tester,
  ) async {
    final updates = controllerWith();
    final opened = <Uri>[];
    await updates.checkForUpdate('1.9.4');
    await pump(tester, updates, openRelease: (url) async => opened.add(url));
    await tester.pumpAndSettle();

    expect(find.text('Klabautermann 9.9.9 is available'), findsOneWidget);
    expect(find.text('View Release'), findsOneWidget);

    await tester.tap(find.text('View Release'));
    expect(opened, [updates.update!.releasesUrl]);
  });

  testWidgets('Android shows the size and Update downloads the APK', (
    tester,
  ) async {
    final updater = ScriptedApkUpdater();
    final updates = controllerWith(updater: updater);
    await updates.checkForUpdate('1.9.4');
    await pump(tester, updates);
    await tester.pumpAndSettle();

    expect(find.text('Klabautermann 9.9.9 is available'), findsOneWidget);
    expect(find.textContaining('download'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);

    await tester.tap(find.text('Update'));
    await tester.pump();
    expect(updater.requested, [apkOf('v9.9.9')]);
  });

  testWidgets('a running download offers Cancel, a finished one Install', (
    tester,
  ) async {
    final updater = ScriptedApkUpdater();
    final updates = controllerWith(updater: updater);
    await updates.checkForUpdate('1.9.4');
    await pump(tester, updates);

    updater.scripted = const ApkUpdateDownloading(1, 2);
    await tester.pumpAndSettle();
    expect(find.textContaining('Downloading Klabautermann 9.9.9'), findsOne);
    expect(find.text('Cancel'), findsOneWidget);

    updater.scripted = const ApkUpdateReady();
    await tester.pumpAndSettle();
    expect(find.text('Klabautermann 9.9.9 is ready to install'), findsOne);
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets('a failed download says why and offers Retry', (tester) async {
    final updater = ScriptedApkUpdater();
    final updates = controllerWith(updater: updater);
    await updates.checkForUpdate('1.9.4');
    await pump(tester, updates);

    updater.scripted = const ApkUpdateFailed(ApkUpdateFailure.verification);
    await tester.pumpAndSettle();

    expect(
      find.text('Klabautermann 9.9.9 could not be installed'),
      findsOneWidget,
    );
    expect(
      find.text('The download did not match the release and was discarded.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('dismiss hides the banner and stops a download', (tester) async {
    final updater = ScriptedApkUpdater();
    final updates = controllerWith(updater: updater);
    await updates.checkForUpdate('1.9.4');
    await pump(tester, updates);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    expect(updates.update, isNull);
    expect(updater.cancels, 1);
    expect(find.text('Klabautermann 9.9.9 is available'), findsNothing);
  });
}
