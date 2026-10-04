import 'package:test/test.dart';

import 'transfer_fakes.dart';

void main() {
  test('addFile removes every newly folded alias', () {
    final fileSystem = FakeTreeFileSystem()
      ..addFile('/A.txt', [1])
      ..addFile('/a.txt', [2])
      ..caseInsensitive = true
      ..addFile('/a.txt', [3]);

    expect(fileSystem.fileBytes, {
      '/a.txt': [3],
    });
  });

  test('delete removes every newly folded alias', () async {
    final fileSystem = FakeTreeFileSystem()
      ..addFile('/A.txt', [1])
      ..addFile('/a.txt', [2])
      ..caseInsensitive = true;

    await fileSystem.delete(fileSystem.entryAt('/a.txt')!);

    expect(fileSystem.fileBytes, isEmpty);
  });
}
