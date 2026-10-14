import 'dart:io';

import 'package:posix/posix.dart' show PosixException;
import 'package:seance_core/catalog.dart' show restrictLocalPathPermissions;
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

  group('local path restriction', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync(
        'seance-core-local-permissions-',
      );
    });

    tearDown(() => directory.deleteSync(recursive: true));

    int modeOf(FileSystemEntity entity) => entity.statSync().mode & 0x1ff;

    test('applies owner-only file and directory modes', () async {
      final file = File('${directory.path}/private')..writeAsStringSync('x');
      final nested = Directory('${directory.path}/nested')..createSync();

      await restrictLocalPathPermissions(file.path, '600');
      await restrictLocalPathPermissions(nested.path, '700');

      expect(modeOf(file), 0x180);
      expect(modeOf(nested), 0x1c0);
    });

    test('fails closed when chmod fails', () async {
      final missing = '${directory.path}/missing';

      await expectLater(
        restrictLocalPathPermissions(missing, '600'),
        throwsA(
          isA<FileSystemException>().having((e) => e.path, 'path', missing),
        ),
      );
    });
  }, skip: !Platform.isLinux && !Platform.isMacOS ? 'POSIX only' : false);
}
