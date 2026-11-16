// The shared picked-file read budget and the save-as route per platform,
// over scripted file_picker and file_selector platforms.
import 'dart:io';

import 'package:file_picker/file_picker.dart' show FilePickerPlatform;
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_marks_picker/picked_files.dart';
import 'package:ghost_marks_picker/testing.dart';

void main() {
  group('readPickedFileBytes', () {
    test('rejects oversized metadata without opening the contents', () async {
      final file = FakePickedFile.bytes('a', [1, 2, 3], reportedLength: 4);
      await expectLater(
        readPickedFileBytes(file, maxBytes: 3),
        throwsA(isA<PickedFileTooLargeException>()),
      );
      expect(file.reads, 0);
    });

    test('streams a pathless provider within the budget', () async {
      final file = FakePickedFile.bytes('a', [1, 2, 3]);
      expect(await readPickedFileBytes(file, maxBytes: 3), [1, 2, 3]);
    });

    test('bounds a stale reported size by the stream itself', () async {
      final file = FakePickedFile.bytes('a', [1, 2, 3, 4], reportedLength: 1);
      await expectLater(
        readPickedFileBytes(file, maxBytes: 3),
        throwsA(isA<PickedFileTooLargeException>()),
      );
    });

    test('reads a platform error as a FileSystemException', () async {
      final file = FakePickedFile.stream(
        'a',
        () => Stream.error(StateError('gone')),
      );
      await expectLater(
        readPickedFileBytes(file, maxBytes: 3),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('saveAs', () {
    late FakeFilePicker picker;
    late FilePickerPlatform originalPicker;
    late FileSelectorPlatform originalSelector;
    final bytes = Uint8List.fromList([1, 2, 3]);

    setUp(() {
      originalPicker = FilePickerPlatform.instance;
      originalSelector = FileSelectorPlatform.instance;
      FilePickerPlatform.instance = picker = FakeFilePicker();
    });

    tearDown(() {
      FilePickerPlatform.instance = originalPicker;
      FileSelectorPlatform.instance = originalSelector;
      debugDefaultTargetPlatformOverride = null;
    });

    Future<String?> save(List<String> written) => saveAs(
      fileName: 'notes.txt',
      mimeType: 'text/plain',
      readBytes: () async => bytes,
      writeTo: (path) async => written.add(path),
    );

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      test(
        '$platform asks the panel for a path and lets the app write',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          final selector = FakeFileSelector(location: '/chosen/notes.txt');
          FileSelectorPlatform.instance = selector;
          final written = <String>[];

          expect(await save(written), '/chosen/notes.txt');
          expect(selector.suggestedNames, ['notes.txt']);
          expect(written, ['/chosen/notes.txt']);
          expect(picker.saves, isEmpty);
        },
      );
    }

    test('a cancelled desktop panel writes nothing', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      FileSelectorPlatform.instance = FakeFileSelector();
      final written = <String>[];

      expect(await save(written), isNull);
      expect(written, isEmpty);
    });

    // file_selector has no iOS save panel; asking it for one threw, which
    // broke Séance's "Download / Save as…" on iOS.
    test('iOS exports the bytes through the document picker', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      FileSelectorPlatform.instance = FakeFileSelector.withoutSavePanel();
      picker.savedTo = Uri.file('/Files/notes.txt');
      final written = <String>[];

      expect(await save(written), '/Files/notes.txt');
      expect(written, isEmpty);
      expect(picker.saves.single.fileName, 'notes.txt');
      expect(picker.saves.single.bytes, bytes);
      expect(picker.saves.single.mimeType, 'text/plain');
    });

    test('iOS keeps a location that is not a file path as a URI', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      picker.savedTo = Uri.parse('https://example.invalid/notes.txt');
      expect(await save([]), 'https://example.invalid/notes.txt');

      picker.savedTo = null;
      expect(await save([]), isNull);
    });

    test('Android has no save panel here', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await expectLater(save([]), throwsUnsupportedError);
    });
  });
}
