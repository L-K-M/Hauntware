import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('post-bump hook fails closed and verifies final state', () {
    final script = File('scripts/release.sh').readAsStringSync();
    final hookStart = script.indexOf("export RELEASE_POST_BUMP='");
    final hookEnd = script.indexOf("'\nexport RELEASE_CI_NOTE", hookStart);

    expect(hookStart, isNonNegative);
    expect(hookEnd, greaterThan(hookStart));

    final hook = script.substring(hookStart, hookEnd);
    final strictMode = hook.indexOf('set -euo pipefail');
    final synchronization = hook.indexOf('    sync');
    final finalCheck = hook.lastIndexOf('    check');

    expect(strictMode, isNonNegative);
    expect(strictMode, lessThan(synchronization));
    expect(finalCheck, greaterThan(synchronization));
    expect(
      hook.substring(finalCheck),
      contains('--version "\${RELEASE_NEW_VERSION}"'),
    );
  });
}
