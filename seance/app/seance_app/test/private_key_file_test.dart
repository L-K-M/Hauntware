import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_marks_picker/testing.dart';
import 'package:seance_app/services/private_key_file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FilePickerPlatform previousPicker;
  late FakeFilePicker picker;

  setUp(() {
    previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker = FakeFilePicker();
  });

  tearDown(() => FilePickerPlatform.instance = previousPicker);

  Matcher tooLarge() => throwsA(
    isA<FormatException>().having(
      (error) => error.message,
      'message',
      'That file is too large to be a private key.',
    ),
  );

  test('rejects oversized metadata without loading file data', () async {
    var read = false;
    Stream<List<int>> source() async* {
      read = true;
      yield const [65];
    }

    picker.picked = [
      FakePickedFile.stream(
        'key',
        source,
        reportedLength: maxPrivateKeyFileBytes + 1,
      ),
    ];

    await expectLater(pickPrivateKeyText(), tooLarge());
    expect(read, isFalse);
  });

  test('reads a key from a pathless provider stream', () async {
    final file = FakePickedFile.bytes('key', [65, 66, 67], reportedLength: 3);
    picker.picked = [file];

    expect(await pickPrivateKeyText(), 'ABC');
    expect(file.reads, 1);
  });

  test('reads the path-only result macOS returns', () async {
    final directory = await Directory.systemTemp.createTemp('seance-key-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/key').writeAsString('ABC');
    picker.picked = [FakePickedFile.path('key', file.path, reportedLength: 3)];

    expect(await pickPrivateKeyText(), 'ABC');
  });

  test('bounds unknown stream sizes and stops reading on overflow', () async {
    var cancelled = false;
    Stream<List<int>> source() async* {
      try {
        yield Uint8List(maxPrivateKeyFileBytes);
        yield const [65];
        fail('read beyond the key size limit');
      } finally {
        cancelled = true;
      }
    }

    picker.picked = [FakePickedFile.stream('key', source)];

    await expectLater(pickPrivateKeyText(), tooLarge());
    expect(cancelled, isTrue);
  });

  test('bounds returned bytes even when the reported size is stale', () async {
    picker.picked = [
      FakePickedFile.bytes(
        'key',
        Uint8List(maxPrivateKeyFileBytes + 1),
        reportedLength: 1,
      ),
    ];

    await expectLater(pickPrivateKeyText(), tooLarge());
  });

  test('rejects non-text bytes with the existing message', () async {
    picker.picked = [
      FakePickedFile.bytes('key', [0xFF], reportedLength: 1),
    ];

    await expectLater(
      pickPrivateKeyText(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'That file is not a text private key.',
        ),
      ),
    );
  });

  test('a platform read failure reads as an unreadable file', () async {
    picker.picked = [
      FakePickedFile.stream('key', () => Stream.error(StateError('gone'))),
    ];

    await expectLater(
      pickPrivateKeyText(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'That file could not be read.',
        ),
      ),
    );
  });

  test('a cancelled pick returns nothing', () async {
    expect(await pickPrivateKeyText(), isNull);
  });
}
