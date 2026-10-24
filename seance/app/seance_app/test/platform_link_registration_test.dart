// The seance:// scheme registration on Android, iOS and macOS
// (docs/design/suite-links.md section 7, F5d-3b). Linux and Windows follow
// with single-instance forwarding.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android routes seance://connect to the launcher activity', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');
    final viewFilter = RegExp(
      r'<intent-filter>\s*'
      r'<action android:name="android\.intent\.action\.VIEW"/>\s*'
      r'<category android:name="android\.intent\.category\.DEFAULT"/>\s*'
      r'<category android:name="android\.intent\.category\.BROWSABLE"/>\s*'
      r'<data android:scheme="seance" android:host="connect"/>\s*'
      r'</intent-filter>',
    );
    // app_links reads the launcher activity; one activity keeps one queue.
    final activity = RegExp(
      r'<activity\b[\s\S]*?</activity>',
    ).firstMatch(manifest)!.group(0)!;
    expect(activity, matches(viewFilter));
    expect(activity, contains('android:launchMode="singleTop"'));
    // Flutter's own deep linking would push the link as a route ahead of
    // the review.
    expect(
      activity,
      matches(
        RegExp(
          r'android:name="flutter_deeplinking_enabled"\s*'
          r'android:value="false"',
        ),
      ),
    );
  });

  for (final platform in ['ios', 'macos']) {
    test('$platform declares the seance scheme and leaves routing to the '
        'intake', () {
      final info = _read('$platform/Runner/Info.plist');
      expect(
        info,
        matches(
          RegExp(
            r'<key>CFBundleURLTypes</key>\s*<array>\s*<dict>\s*'
            r'<key>CFBundleURLName</key>\s*<string>ch\.lkmc\.seance</string>\s*'
            r'<key>CFBundleURLSchemes</key>\s*<array>\s*'
            r'<string>seance</string>\s*</array>',
          ),
        ),
      );
      expect(
        info,
        matches(RegExp(r'<key>FlutterDeepLinkingEnabled</key>\s*<false/>')),
      );
    });
  }

  test('the app listens only where the scheme is registered', () {
    final main = _read('lib/main.dart');
    expect(main, contains('AppLinks().uriLinkStream.listen('));
    expect(
      main,
      contains('Platform.isAndroid || Platform.isIOS || Platform.isMacOS'),
    );
    // The settings window's engine returns before subscribing.
    expect(
      main.indexOf('runSettingsWindow()'),
      lessThan(main.indexOf('AppLinks()')),
    );
  });

  test('app_links is pinned to the version Poltergeist runs', () {
    final pin = RegExp(r'^\s*app_links:\s*(\S+)\s*$', multiLine: true);
    final seance = pin.firstMatch(_read('pubspec.yaml'))?.group(1);
    final poltergeist = pin
        .firstMatch(
          _read('../../../poltergeist/app/poltergeist_app/pubspec.yaml'),
        )
        ?.group(1);
    // Two missing pins would otherwise compare equal.
    expect(seance, isNotNull, reason: 'Séance pins app_links');
    expect(poltergeist, isNotNull, reason: 'Poltergeist pins app_links');
    expect(seance, poltergeist);
  });
}

String _read(String path) => File(path).readAsStringSync();
