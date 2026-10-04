import 'dart:io';

import 'package:planchette_core/src/native_file_operations.dart';
import 'package:test/test.dart';

void main() {
  test(
    'failed Android source cleanup never deletes a replaced destination',
    () {
      final files = {'source': 'original'};
      final unlinked = <String>[];
      expect(
        () => renameUsingHardLink(
          'source',
          'destination',
          link: () {
            files['destination'] = files['source']!;
            return 0;
          },
          unlink: (path) {
            unlinked.add(path);
            if (path == 'source') {
              files['destination'] = 'concurrent change';
              return -1;
            }
            files.remove(path);
            return 0;
          },
          readError: () => 13,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(files['source'], 'original');
      expect(files['destination'], 'concurrent change');
      expect(unlinked, ['source']);
    },
  );

  test('a failed hard-link publication never tries source cleanup', () {
    expect(
      () => renameUsingHardLink(
        'source',
        'destination',
        link: () => -1,
        unlink: (_) => throw StateError('must not unlink'),
        readError: () => 17,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
