import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_apk_update/ghost_apk_update.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/app_menus.dart';
import 'package:seance_app/ui/server_list_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// An updater whose state the test sets, recording what the banner asks.
class _ScriptedUpdater extends ApkUpdater {
  ApkUpdateState _scripted = const ApkUpdateIdle();
  final requested = <ApkRelease>[];
  var cancels = 0;

  @override
  ApkUpdateState get state => _scripted;

  set scripted(ApkUpdateState next) {
    _scripted = next;
    notifyListeners();
  }

  @override
  Future<void> update(ApkRelease release) async => requested.add(release);

  @override
  void cancel() => cancels++;
}

final _apk = ReleaseAsset(
  name: AppState.androidReleaseAsset,
  downloadUrl: Uri.parse('https://example.com/v1.10.0/seance-android.apk'),
  size: 74211084,
  sha256: 'f6fdd1e716651a6c7392ec2d8bd74f47863091858f09f55cf0f67e5bf5e81d15',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    await services?.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    state = null;
    services = null;
    directory = null;
  });

  /// The rail with a newer release on offer; [updater] stands in for the
  /// Android build's, absent everywhere else.
  Future<void> pumpBanner(
    WidgetTester tester, {
    ApkUpdater? updater,
    Map<String, ReleaseAsset> assets = const {},
  }) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-update-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, (_) async => directory!.path);
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!, apkUpdater: updater);
      state!.updateInfo = UpdateInfo(
        latestVersion: '1.10.0',
        releasesUrl: Uri.parse('https://example.com/releases'),
        assets: assets,
      );
    });
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.android),
        home: AppScope(
          state: state!,
          child: AppMenus(
            child: ServerListPane(
              posture: ServerListPosture.rail,
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('without an updater the banner links to the release page', (
    tester,
  ) async {
    await pumpBanner(tester, assets: {_apk.name: _apk});

    expect(find.text('Séance 1.10.0 is available.'), findsOneWidget);
    expect(find.text('View release'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
  });

  testWidgets('a release without this build\'s APK still links out', (
    tester,
  ) async {
    await pumpBanner(tester, updater: _ScriptedUpdater());

    expect(find.text('View release'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
  });

  testWidgets('Update downloads the release APK in place', (tester) async {
    final updater = _ScriptedUpdater();
    await pumpBanner(tester, updater: updater, assets: {_apk.name: _apk});

    expect(find.text('Séance 1.10.0 is available (74 MB).'), findsOneWidget);
    expect(find.text('View release'), findsNothing);
    await tester.tap(find.text('Update'));
    await tester.pump();

    expect(updater.requested, [
      ApkRelease(url: _apk.downloadUrl, size: _apk.size, sha256: _apk.sha256),
    ]);
  });

  testWidgets('a download shows progress and only Cancel', (tester) async {
    final updater = _ScriptedUpdater();
    await pumpBanner(tester, updater: updater, assets: {_apk.name: _apk});

    updater.scripted = const ApkUpdateDownloading(25, 100);
    await tester.pump();

    expect(find.text('Downloading Séance 1.10.0…'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.25);
    expect(find.byTooltip('Dismiss'), findsNothing);

    await tester.tap(find.text('Cancel'));
    expect(updater.cancels, 1);
  });

  testWidgets('a backed-out installer reopens with Install', (tester) async {
    final updater = _ScriptedUpdater();
    await pumpBanner(tester, updater: updater, assets: {_apk.name: _apk});

    updater.scripted = const ApkUpdateReady();
    await tester.pump();

    expect(find.text('Séance 1.10.0 is ready to install.'), findsOneWidget);
    await tester.tap(find.text('Install'));
    expect(updater.requested, hasLength(1));
  });

  testWidgets('each failure says what went wrong and offers Retry', (
    tester,
  ) async {
    final updater = _ScriptedUpdater();
    await pumpBanner(tester, updater: updater, assets: {_apk.name: _apk});

    for (final (failure, message) in [
      (ApkUpdateFailure.download, 'Séance 1.10.0 could not be downloaded.'),
      (
        ApkUpdateFailure.verification,
        'The Séance 1.10.0 download was damaged and was discarded.',
      ),
      (ApkUpdateFailure.installer, 'Android could not open the installer.'),
    ]) {
      updater.scripted = ApkUpdateFailed(failure);
      await tester.pump();

      expect(find.text(message), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byTooltip('Dismiss'), findsOneWidget);
    }
  });

  testWidgets('dismissing cancels a running download', (tester) async {
    final updater = _ScriptedUpdater();
    await pumpBanner(tester, updater: updater, assets: {_apk.name: _apk});
    updater.scripted = const ApkUpdateDownloading(25, 100);
    await tester.pump();

    state!.dismissUpdateNotice();
    await tester.pump();

    expect(updater.cancels, 1);
    expect(find.textContaining('Séance 1.10.0'), findsNothing);
  });

  test('every release publishes the asset an installed build updates from', () {
    // Renaming it would strand every installed Android build on its
    // version: they look the old name up for good.
    final manifest = File('../../../scripts/release-manifest.txt');
    expect(
      manifest.readAsLinesSync().map((line) => line.trim()),
      contains(AppState.androidReleaseAsset),
    );
  });
}
