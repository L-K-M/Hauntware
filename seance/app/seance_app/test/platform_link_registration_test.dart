// The seance:// scheme registration on every native platform
// (docs/design/suite-links.md section 7, F5d-3b and F5d-3c), with
// single-instance forwarding on Linux and Windows.
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

  test('Linux runs one instance and hands it the link', () {
    final runner = _read('linux/runner/my_application.cc');
    expect(runner, isNot(contains('G_APPLICATION_NON_UNIQUE')));
    expect(
      runner,
      matches(
        RegExp(
          r'G_APPLICATION_HANDLES_COMMAND_LINE\s*\|\s*'
          r'G_APPLICATION_HANDLES_OPEN',
        ),
      ),
    );
    // local_command_line leaves the arguments to GApplication, which
    // forwards them to the primary instance's command-line handler.
    final localCommandLine = RegExp(
      r'my_application_local_command_line\([\s\S]*?\n}',
    ).firstMatch(runner)!.group(0)!;
    expect(localCommandLine, contains('return FALSE;'));
    // A second activation raises the main window rather than opening one.
    expect(runner, contains('gtk_window_present(existing);'));

    final packaging = _read('../../scripts/package-linux.sh');
    expect(packaging, contains(r'Exec=$2 %u'));
    expect(packaging, contains('MimeType=x-scheme-handler/seance;'));
  });

  test('Windows registers the scheme and forwards to the primary', () {
    final scheme = _read('windows/runner/deep_link_scheme.cpp');
    expect(scheme, contains(r'L"Software\\Classes\\seance"'));
    expect(scheme, contains('L"URL:Seance"'));
    expect(scheme, contains('L"seance:"'));
    expect(scheme, contains(r'L"Local\\ch.lkmc.seance.deep-link-primary-v1"'));
    expect(scheme, isNot(contains('oltergeist:')));
    // MSVC reads the runner as the system code page.
    expect(scheme.runes.every((rune) => rune < 0x80), isTrue);

    final main = _read('windows/runner/main.cpp');
    expect(
      main.indexOf('ClaimOrForwardDeepLinkInstance'),
      lessThan(main.indexOf('FlutterWindow window(project)')),
    );
    expect(
      _read('windows/runner/flutter_window.cpp'),
      contains('MarkPrimaryDeepLinkWindow(GetHandle())'),
    );
    expect(
      _read('windows/runner/CMakeLists.txt'),
      contains('"deep_link_scheme.cpp"'),
    );
  });

  test('the app listens on every native platform', () {
    final main = _read('lib/main.dart');
    expect(main, contains('AppLinks().uriLinkStream.listen('));
    expect(main, contains('bool get _receivesLinks => !kIsWeb;'));
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
