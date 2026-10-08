import 'dart:io';

import 'package:posix/posix.dart' show PosixException;
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  test('owner-only restriction reports chmod failure', () {
    final directory = Directory.systemTemp.createTempSync(
      'seance-core-permissions-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final missingFile = File('${directory.path}/missing');

    expect(
      () => restrictFileToOwner(missingFile),
      throwsA(isA<PosixException>()),
    );
  }, skip: !Platform.isLinux && !Platform.isMacOS ? 'POSIX only' : false);
}
