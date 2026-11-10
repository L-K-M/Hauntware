// The update check Klabautermann wires from its composition root (c3
// §shells, D19/D23): the shared controller over the app's own checker
// configuration. The pinned contract is the request shape — one plain GET
// of the static endpoint, no query, no body — and the app's user agent,
// because GitHub requires each app to name itself.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_apk_update/ghost_apk_update.dart';
import 'package:ghost_update/ghost_update.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../support/scripted_apk_updater.dart';

void main() {
  final requests = <http.BaseRequest>[];

  http.Client clientWith(Object? body, {int status = 200}) =>
      http_testing.MockClient((request) async {
        requests.add(request);
        return http.Response(body is String ? body : jsonEncode(body), status);
      });

  http.Client failingClient() => http_testing.MockClient((request) async {
    requests.add(request);
    throw const SocketException('offline');
  });

  Map<String, Object?> releaseJson(String tag) => {
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
  };

  UpdateChecker checkerWith(Object? body, {int status = 200}) => UpdateChecker(
    repo: klabautermannUpdateRepo,
    userAgent: klabautermannUpdateUserAgent,
    client: clientWith(body, status: status),
  );

  UpdateCheckController controllerWith(
    UpdateChecker checker, {
    ScriptedApkUpdater? updater,
    bool enabled = true,
    Future<void> Function(bool enabled)? onEnabledChanged,
  }) => UpdateCheckController(
    checker: checker,
    apkUpdater: updater,
    androidReleaseAsset: klabautermannAndroidReleaseAsset,
    enabled: enabled,
    onEnabledChanged: onEnabledChanged,
  );

  setUp(requests.clear);

  group('checkForUpdate', () {
    test('a newer release tag surfaces an UpdateInfo', () async {
      final controller = controllerWith(checkerWith(releaseJson('v9.9.9')));
      var notified = 0;
      controller.addListener(() => notified++);

      await controller.checkForUpdate('1.9.4');

      expect(controller.update, isNotNull);
      expect(controller.update!.latestVersion, '9.9.9');
      expect(notified, 1);
    });

    test('the request is one GET with Klabautermann\'s user agent', () async {
      final controller = controllerWith(checkerWith(releaseJson('v9.9.9')));
      await controller.checkForUpdate('1.9.4');

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'https://api.github.com/repos/L-K-M/Hauntware/releases/latest',
      );
      expect(request.url.query, isEmpty);
      expect(request.headers['User-Agent'], klabautermannUpdateUserAgent);
      // A link-only check carries nothing to compare against server-side;
      // the version stays on the device.
      expect((request as http.Request).body, isEmpty);
      expect(
        controller.update!.releasesUrl.toString(),
        'https://github.com/L-K-M/Hauntware/releases/latest',
      );
    });

    test('an up-to-date tag surfaces nothing', () async {
      final controller = controllerWith(checkerWith(releaseJson('v1.9.4')));
      await controller.checkForUpdate('1.9.4');
      expect(controller.update, isNull);
    });

    test(
      'drafts, prereleases, offline, and rate limits surface nothing',
      () async {
        for (final body in [
          {...releaseJson('v9.9.9'), 'draft': true},
          {...releaseJson('v9.9.9'), 'prerelease': true},
          'not json',
        ]) {
          final controller = controllerWith(checkerWith(body));
          await controller.checkForUpdate('1.9.4');
          expect(controller.update, isNull, reason: 'body: $body');
        }
        final offline = controllerWith(
          UpdateChecker(
            repo: klabautermannUpdateRepo,
            userAgent: klabautermannUpdateUserAgent,
            client: failingClient(),
          ),
        );
        await offline.checkForUpdate('1.9.4');
        expect(offline.update, isNull);
        final rateLimited = controllerWith(checkerWith('', status: 403));
        await rateLimited.checkForUpdate('1.9.4');
        expect(rateLimited.update, isNull);
      },
    );

    test(
      'opting out while the launch check runs keeps its answer away',
      () async {
        final release = Completer<http.Response>();
        final controller = controllerWith(
          UpdateChecker(
            repo: klabautermannUpdateRepo,
            userAgent: klabautermannUpdateUserAgent,
            client: http_testing.MockClient((request) => release.future),
          ),
        );

        final check = controller.checkForUpdate('1.9.4');
        await controller.setEnabled(false);
        release.complete(http.Response(jsonEncode(releaseJson('v9.9.9')), 200));
        await check;

        expect(controller.update, isNull);
      },
    );

    test('disabled at boot: no request ever leaves', () async {
      final controller = controllerWith(
        checkerWith(releaseJson('v9.9.9')),
        enabled: false,
      );
      await controller.checkForUpdate('1.9.4');
      expect(controller.update, isNull);
      expect(requests, isEmpty);
    });
  });

  group('dismiss and the opt-out toggle', () {
    test('dismiss clears the banner for this session', () async {
      final controller = controllerWith(checkerWith(releaseJson('v9.9.9')));
      await controller.checkForUpdate('1.9.4');
      var notified = 0;
      controller.addListener(() => notified++);

      controller.dismiss();
      expect(controller.update, isNull);
      expect(notified, 1);
      // Dismissing nothing is a no-op, not a rebuild signal.
      controller.dismiss();
      expect(notified, 1);
    });

    test('setEnabled(false) persists, clears a live banner, and skips '
        'later checks', () async {
      final saved = <bool>[];
      final controller = controllerWith(
        checkerWith(releaseJson('v9.9.9')),
        onEnabledChanged: (value) async => saved.add(value),
      );
      await controller.checkForUpdate('1.9.4');
      expect(controller.update, isNotNull);

      await controller.setEnabled(false);
      expect(saved, [false]);
      expect(controller.enabled, isFalse);
      expect(controller.update, isNull);

      requests.clear();
      await controller.checkForUpdate('1.9.4');
      expect(requests, isEmpty);
    });

    test('a failed persist reverts the toggle and rethrows', () async {
      final controller = controllerWith(
        checkerWith(releaseJson('v9.9.9')),
        onEnabledChanged: (_) async => throw StateError('disk full'),
      );
      await expectLater(
        controller.setEnabled(false),
        throwsA(isA<StateError>()),
      );
      expect(controller.enabled, isTrue);
    });
  });

  group('checkNow (the menu\'s Check for Updates…)', () {
    test('runs even with the launch check turned off', () async {
      final controller = controllerWith(
        checkerWith(releaseJson('v9.9.9')),
        enabled: false,
      );
      var notified = 0;
      controller.addListener(() => notified++);

      final info = await controller.checkNow('1.9.4');

      expect(requests, hasLength(1));
      expect(info?.latestVersion, '9.9.9');
      // What the user asked for lands in the banner like the launch
      // check's would.
      expect(controller.update, same(info));
      expect(notified, 1);
    });

    test('answers null for up to date and for a failed check alike', () async {
      final current = controllerWith(checkerWith(releaseJson('v1.9.4')));
      expect(await current.checkNow('1.9.4'), isNull);

      final offline = controllerWith(
        UpdateChecker(
          repo: klabautermannUpdateRepo,
          userAgent: klabautermannUpdateUserAgent,
          client: failingClient(),
        ),
      );
      expect(await offline.checkNow('1.9.4'), isNull);
      expect(offline.update, isNull);
    });
  });

  group('Android in-place update', () {
    test('Update downloads the release APK the check found', () async {
      final updater = ScriptedApkUpdater();
      final controller = controllerWith(
        checkerWith(releaseWithApk('v9.9.9')),
        updater: updater,
      );
      await controller.checkForUpdate('1.9.4');

      expect(controller.updateApk, apkOf('v9.9.9'));
      await controller.installUpdate();

      expect(updater.requested, [apkOf('v9.9.9')]);
      // The check stays one GET; the download is the updater's alone.
      expect(requests, hasLength(1));
    });

    test('an APK under another asset name is ignored', () async {
      final updater = ScriptedApkUpdater();
      final controller = controllerWith(
        UpdateChecker(
          repo: klabautermannUpdateRepo,
          userAgent: klabautermannUpdateUserAgent,
          client: clientWith({
            'tag_name': 'v9.9.9',
            'draft': false,
            'prerelease': false,
            'assets': [
              {
                'name': 'someone-else.apk',
                'browser_download_url':
                    'https://github.com/L-K-M/Hauntware/releases/download/'
                    'v9.9.9/someone-else.apk',
                'size': 103670866,
                'digest':
                    'sha256:'
                    '0be7459344d614eb920cce957e33c6d272a1a4540b291b16a580cee7'
                    'adac64f3',
              },
            ],
          }),
        ),
        updater: updater,
      );
      await controller.checkForUpdate('1.9.4');

      expect(controller.update, isNotNull);
      expect(controller.updateApk, isNull);
      await controller.installUpdate();
      expect(updater.requested, isEmpty);
    });

    test('off Android the release only links out', () async {
      final controller = controllerWith(checkerWith(releaseWithApk('v9.9.9')));
      await controller.checkForUpdate('1.9.4');

      expect(controller.update, isNotNull);
      expect(controller.updateApk, isNull);
      expect(controller.download, isA<ApkUpdateIdle>());
      await controller.installUpdate();
    });

    test('a release without the APK only links out', () async {
      final updater = ScriptedApkUpdater();
      final controller = controllerWith(
        checkerWith(releaseJson('v9.9.9')),
        updater: updater,
      );
      await controller.checkForUpdate('1.9.4');

      expect(controller.updateApk, isNull);
      await controller.installUpdate();
      expect(updater.requested, isEmpty);
    });

    test('download progress notifies through the controller', () async {
      final updater = ScriptedApkUpdater();
      final controller = controllerWith(
        checkerWith(releaseWithApk('v9.9.9')),
        updater: updater,
      );
      var notified = 0;
      controller.addListener(() => notified++);

      updater.scripted = const ApkUpdateDownloading(1, 2);

      expect(notified, 1);
      expect(controller.download, isA<ApkUpdateDownloading>());
    });

    test('dismissing or opting out stops a running download', () async {
      final updater = ScriptedApkUpdater();
      final controller = controllerWith(
        checkerWith(releaseWithApk('v9.9.9')),
        updater: updater,
      );
      await controller.checkForUpdate('1.9.4');

      controller.dismiss();
      expect(updater.cancels, 1);

      await controller.checkForUpdate('1.9.4');
      await controller.setEnabled(false);
      expect(updater.cancels, 2);
    });

    test('every release publishes the asset installed builds look up', () {
      // Renaming it would strand every installed Android build on its
      // version: they look the old name up for good.
      final manifest = File('../../../scripts/release-manifest.txt');
      expect(
        manifest.readAsLinesSync().map((line) => line.trim()),
        contains(klabautermannAndroidReleaseAsset),
      );
    });
  });
}
