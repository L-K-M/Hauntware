import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// The identities fixed by the owner on 2026-10-10 (04 section 12.3, D38).
// Every value is permanent once anything ships.
const _androidId = 'ch.lkmc.klabautermann';
const _appleId = 'ch.lkmc.klabautermannApp';
const _linuxBinaryName = 'klabautermann';
const _linuxStartupWmClass = 'Ch.lkmc.klabautermann';
const _macBundleName = 'Klabautermann.app';
const _macExecutableName = 'Klabautermann';
const _productName = 'Klabautermann';
const _windowsCompanyName = 'ch.lkmc';
const _windowsExecutableName = 'klabautermann.exe';
const _pngSignature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
final _flutterEphemeralPath = RegExp(
  r'[/\\]flutter[/\\]ephemeral[/\\]',
  caseSensitive: false,
);

void main() {
  test('keeps platform identifiers and product names aligned', () {
    expect(
      _read('android/app/build.gradle.kts'),
      allOf(
        contains('namespace = "$_androidId"'),
        contains('applicationId = "$_androidId"'),
      ),
    );
    expect(
      _read('android/app/src/main/AndroidManifest.xml'),
      contains('android:label="$_productName"'),
    );
    expect(
      RegExp(
        RegExp.escape('PRODUCT_BUNDLE_IDENTIFIER = $_appleId;'),
      ).allMatches(_read('ios/Runner.xcodeproj/project.pbxproj')),
      hasLength(3),
    );
    expect(
      _read('macos/Runner/Configs/AppInfo.xcconfig'),
      allOf(
        contains('PRODUCT_BUNDLE_IDENTIFIER = $_appleId'),
        contains('PRODUCT_NAME = $_productName'),
      ),
    );
    expect(
      _read('linux/CMakeLists.txt'),
      allOf(
        contains('set(BINARY_NAME "$_linuxBinaryName")'),
        contains('set(APPLICATION_ID "$_androidId")'),
      ),
    );
    expect(
      _read('windows/runner/Runner.rc'),
      allOf(
        contains('VALUE "CompanyName", "$_windowsCompanyName"'),
        contains('VALUE "ProductName", "$_productName"'),
        contains('VALUE "OriginalFilename", "$_windowsExecutableName"'),
      ),
    );
  });

  test('derives the Linux WM class from the application id', () {
    expect(
      '${_androidId[0].toUpperCase()}${_androidId.substring(1)}',
      _linuxStartupWmClass,
    );
  });

  test('contains no default organization identifiers', () {
    final offenders = <String>[];
    for (final entity in Directory.current.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !_isTextProjectFile(entity.path)) continue;

      // Interpolated so this scan does not flag its own source file.
      if (_read(entity.path).contains('com${'.'}example')) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
  });

  test('grants release APKs network access', () {
    // Debug and profile builds add INTERNET for tooling only; without it
    // in the main manifest a release APK reaches neither SSH nor sync.
    final manifest = _read('android/app/src/main/AndroidManifest.xml');

    expect(
      manifest,
      contains('<uses-permission android:name="android.permission.INTERNET"/>'),
    );
  });

  test('keeps shipped application and bundle names ASCII', () {
    for (final name in [_linuxBinaryName, _macExecutableName, _productName]) {
      expect(ascii.encode(name), hasLength(name.length));
    }
  });

  test('keeps native metadata consistent with the Unlicense', () {
    for (final path in [
      'macos/Runner/Configs/AppInfo.xcconfig',
      'windows/runner/Runner.rc',
    ]) {
      expect(_read(path), isNot(contains('All rights reserved')));
    }
  });

  test('keeps macOS product references aligned with the bundle name', () {
    final project = _read('macos/Runner.xcodeproj/project.pbxproj');
    final scheme = _read(
      'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
    );

    expect(
      project,
      allOf(
        contains('path = "$_macBundleName"'),
        contains('productReference = '),
        contains(
          'TEST_HOST = "\$(BUILT_PRODUCTS_DIR)/$_macBundleName/'
          '\$(BUNDLE_EXECUTABLE_FOLDER_PATH)/$_macExecutableName"',
        ),
        isNot(contains('klabautermann_app.app')),
      ),
    );
    expect(
      scheme,
      allOf(
        contains('BuildableName = "$_macBundleName"'),
        isNot(contains('BuildableName = "klabautermann_app.app"')),
      ),
    );
  });

  test('uses the product name in the native macOS menu and window', () {
    final menu = _read('macos/Runner/Base.lproj/MainMenu.xib');

    expect(menu, isNot(contains('APP_NAME')));
    expect(menu, contains('title="About $_productName"'));
    expect(menu, contains('title="Hide $_productName"'));
    expect(menu, contains('title="Quit $_productName"'));
    expect(menu, contains('<window title="$_productName"'));
  });

  test('keeps macOS desktop builds unsandboxed', () {
    for (final path in [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      expect(
        _read(path),
        isNot(contains('com.apple.security.app-sandbox')),
        reason: '$path must allow reading ~/.ssh and identity files',
      );
    }
  });

  test('guards late Windows font changes after teardown', () {
    final runner = _read('windows/runner/flutter_window.cpp');

    expect(
      runner,
      contains(
        'case WM_FONTCHANGE:\n'
        '      if (flutter_controller_) {\n'
        '        flutter_controller_->engine()->ReloadSystemFonts();',
      ),
    );
  });

  // The largest generated launcher is the 1024px iOS marketing icon, so the
  // master must be square and at least that big (never upscaled).
  test('master icon is a square PNG of at least 1024px', () {
    final bytes = File(
      '../../media-sources/klabautermann-icon.png',
    ).readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    final width = data.getUint32(16);

    expect(bytes.sublist(0, _pngSignature.length), _pngSignature);
    expect(width, greaterThanOrEqualTo(1024));
    expect(data.getUint32(20), width);
  });

  test('excludes generated Flutter directories case-insensitively', () {
    expect(
      _isTextProjectFile('macos/Flutter/ephemeral/Generated.xcconfig'),
      isFalse,
    );
  });
}

/// Line endings normalized, so a CRLF checkout reads the same.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

bool _isTextProjectFile(String path) {
  if (path.contains(
    '${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}',
  )) {
    return false;
  }
  if (path.contains(
    '${Platform.pathSeparator}build${Platform.pathSeparator}',
  )) {
    return false;
  }
  if (path.contains(_flutterEphemeralPath)) {
    return false;
  }

  return const {
    '.dart',
    '.gradle',
    '.kts',
    '.plist',
    '.swift',
    '.xml',
    '.xcconfig',
    '.pbxproj',
    '.cmake',
    '.cpp',
    '.cc',
    '.h',
    '.rc',
  }.any(path.endsWith);
}
