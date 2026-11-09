// The Linux runners' view background: transparent, as in Poltergeist and
// Planchette, so a resize shows the GTK window background (which follows
// the desktop's light or dark theme) instead of the template's black flash.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final runner in [
    'linux/runner/my_application.cc',
    'linux/runner/settings_window.cc',
  ]) {
    test('$runner draws a transparent view background', () {
      final source = File(runner).readAsStringSync();
      expect(
        source,
        contains('gdk_rgba_parse(&background_color, "#00000000");'),
      );
      expect(source, isNot(contains('"#000000"')));
    });
  }
}
