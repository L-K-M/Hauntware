import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('maintainer script delegates to the tested Dart CLI', () {
    final script = File('scripts/finalize-release.sh').readAsStringSync();

    expect(script, contains('tool/release_finalize/bin/finalize_release.dart'));
    expect(script, contains(r'"$@"'));
    expect(script, isNot(contains('GPG_FINGERPRINT')));
  });
}
