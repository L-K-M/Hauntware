import 'dart:io';

import 'package:seance_core/catalog.dart' show syncLocalDirectory;
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('seance-core-dir-sync-');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('flushes an existing directory', () async {
    await syncLocalDirectory(directory);
  });

  test('reports a directory the native primitive cannot open', () async {
    final missing = Directory('${directory.path}/missing');

    await expectLater(
      syncLocalDirectory(missing),
      throwsA(isA<FileSystemException>()),
    );
  }, skip: Platform.isLinux ? false : 'Linux native primitive only');
}
