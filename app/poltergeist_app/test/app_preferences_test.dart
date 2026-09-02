import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/settings_store.dart';

import 'support/memory_settings_file_system.dart';

const _settingsPath = '/support/settings.json';

void main() {
  test('accepts integer-valued persisted geometry and pane ratio', () async {
    final files = MemorySettingsFileSystem()
      ..contents[_settingsPath] =
          '{"layout.paneRatio":1,"window.left":80,"window.top":60,'
          '"window.width":1180,"window.height":760}';
    final preferences = AppPreferences(
      store: SettingsStore(path: _settingsPath, fileSystem: files),
    );

    expect(await preferences.loadPaneRatio(), 1);
    expect(
      await preferences.loadWindowBounds(),
      const Rect.fromLTWH(80, 60, 1180, 760),
    );
  });
}
