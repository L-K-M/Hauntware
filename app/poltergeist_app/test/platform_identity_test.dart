import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const _organization = 'com.lkm';
const _androidId = '$_organization.poltergeist_app';
const _appleId = 'com.lkm.poltergeistApp';
const _linuxBinaryName = 'poltergeist';
const _linuxDesktopId = 'com.lkm.poltergeist_app';
const _linuxStartupWmClass = 'Com.lkm.poltergeist_app';
const _macBundleName = 'Poltergeist.app';
const _macExecutableName = 'Poltergeist';
const _productName = 'Poltergeist';

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
      _read('ios/Runner.xcodeproj/project.pbxproj'),
      contains('PRODUCT_BUNDLE_IDENTIFIER = $_appleId;'),
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
      contains('VALUE "ProductName", "$_productName"'),
    );
  });

  test('contains no default organization identifiers', () {
    final offenders = <String>[];
    for (final entity in Directory.current.listSync(recursive: true)) {
      if (entity is! File || !_isTextProjectFile(entity.path)) continue;
      if (_read(entity.path).contains('com${'.'}example')) {
        offenders.add(entity.path);
      }
    }

    expect(offenders, isEmpty);
  });

  test('keeps shipped application and bundle names ASCII', () {
    for (final name in [_linuxBinaryName, _macExecutableName, _productName]) {
      expect(ascii.encode(name), hasLength(name.length));
    }
  });

  test('keeps the Linux desktop entry aligned with WM_CLASS', () {
    expect(
      '${_linuxDesktopId[0].toUpperCase()}${_linuxDesktopId.substring(1)}',
      _linuxStartupWmClass,
    );
    expect(
      _read('../../scripts/package-linux.sh'),
      allOf(
        contains('BUNDLE_EXECUTABLE="$_linuxBinaryName"'),
        contains('LINUX_APPLICATION_ID="$_linuxDesktopId"'),
        contains(r'LINUX_STARTUP_WM_CLASS="${LINUX_APPLICATION_ID^}"'),
        contains(r'LINUX_DESKTOP_FILE="$LINUX_APPLICATION_ID.desktop"'),
        contains('StartupWMClass=\$LINUX_STARTUP_WM_CLASS'),
        contains(r'$LINUX_DESKTOP_FILE'),
      ),
    );
  });

  test('fails closed when a committed platform scaffold is missing', () {
    expect(
      _read('../../scripts/build.sh'),
      allOf(
        contains('platform scaffold is missing'),
        isNot(contains('flutter create --org')),
      ),
    );
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
        isNot(contains('poltergeist_app.app')),
      ),
    );
    expect(
      scheme,
      allOf(
        contains('BuildableName = "$_macBundleName"'),
        isNot(contains('BuildableName = "poltergeist_app.app"')),
      ),
    );
  });

  test('keeps macOS desktop builds unsandboxed', () {
    for (final path in [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      expect(
        _read(path),
        isNot(contains('com.apple.security.app-sandbox')),
        reason: '$path must allow arbitrary filesystem access',
      );
    }
  });

  test('preserves the configured macOS titlebar during show', () {
    final lifecycle = _read('lib/services/desktop_window_lifecycle.dart');

    expect(lifecycle, contains('enableFullSizeContentView()'));
    expect(lifecycle, contains('makeTitlebarTransparent()'));
    expect(lifecycle, contains('hideTitle()'));
    expect(
      lifecycle,
      isNot(contains('titleBarStyle: TitleBarStyle.normal')),
    );
  });

  test('master icon is a 1024px square PNG', () {
    final bytes = File(
      '../../media-sources/poltergeist-icon.png',
    ).readAsBytesSync();
    final data = ByteData.sublistView(Uint8List.fromList(bytes));

    expect(bytes.sublist(1, 4), [0x50, 0x4e, 0x47]);
    expect(data.getUint32(16), 1024);
    expect(data.getUint32(20), 1024);
  });
}

String _read(String path) => File(path).readAsStringSync();

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
  if (path.contains(
    '${Platform.pathSeparator}flutter${Platform.pathSeparator}ephemeral${Platform.pathSeparator}',
  )) {
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
