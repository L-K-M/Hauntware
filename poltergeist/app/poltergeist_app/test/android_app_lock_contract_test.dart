import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;

void main() {
  // local_auth's AndroidX biometric fallback needs an AppCompat theme,
  // including on the API 24-27 devices these clients still support.
  for (final product in ['seance', 'poltergeist', 'klabautermann']) {
    test('$product has a compatible Android device-authentication host', () {
      final main = '../../../$product/app/${product}_app/android/app/src/main';
      expect(
        File('$main/AndroidManifest.xml').readAsStringSync(),
        contains('android.permission.USE_BIOMETRIC'),
      );
      final activity = Directory('$main/kotlin')
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere(
            (file) => paths.basename(file.path) == 'MainActivity.kt',
          );
      expect(
        activity.readAsStringSync(),
        matches(
          RegExp(r'class\s+MainActivity\b[^\{]*:\s*FlutterFragmentActivity\('),
        ),
      );
      final resources = Directory('$main/res');
      final files = resources
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => paths.basename(file.path) == 'styles.xml');
      var checked = 0;
      for (final file in files) {
        for (final match in RegExp(
          r'<style\b[^>]*>',
        ).allMatches(file.readAsStringSync())) {
          final tag = match.group(0)!;
          final name = RegExp(r'\bname="([^"]+)"').firstMatch(tag)?.group(1);
          if (name != 'LaunchTheme' && name != 'NormalTheme') continue;
          final parent = RegExp(
            r'\bparent="([^"]+)"',
          ).firstMatch(tag)?.group(1);
          expect(
            parent?.replaceFirst('@style/', '').startsWith('Theme.AppCompat.'),
            isTrue,
            reason: '${file.path}: $name must support local_auth, not $parent',
          );
          checked++;
        }
      }
      expect(checked, greaterThanOrEqualTo(2));
    });
  }
}
