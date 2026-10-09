import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// The static picker API has no public injection seam.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/private_key_file.dart';

class _KeyPicker extends FilePickerPlatform {
  FilePickerResult? result;
  bool requestedData = false;
  bool requestedStream = false;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    requestedData = withData;
    requestedStream = withReadStream;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FilePickerPlatform previousPicker;
  late _KeyPicker picker;

  setUp(() {
    previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker = _KeyPicker();
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

    picker.result = FilePickerResult([
      PlatformFile(
        name: 'key',
        size: maxPrivateKeyFileBytes + 1,
        readStream: source(),
      ),
    ]);

    await expectLater(pickPrivateKeyText(), tooLarge());
    expect(picker.requestedData, isFalse);
    expect(read, isFalse);
  });

  test('reads a key from a pathless provider stream', () async {
    picker.result = FilePickerResult([
      PlatformFile(
        name: 'key',
        size: 3,
        readStream: Stream.value([65, 66, 67]),
      ),
    ]);

    expect(await pickPrivateKeyText(), 'ABC');
    expect(picker.requestedData, isFalse);
    expect(picker.requestedStream, isTrue);
  });

  test('reads the path-only result macOS returns', () async {
    final directory = await Directory.systemTemp.createTemp('seance-key-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/key').writeAsString('ABC');
    picker.result = FilePickerResult([
      PlatformFile(name: 'key', path: file.path, size: 3),
    ]);

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

    picker.result = FilePickerResult([
      PlatformFile(name: 'key', size: 0, readStream: source()),
    ]);

    await expectLater(pickPrivateKeyText(), tooLarge());
    expect(cancelled, isTrue);
  });

  test('bounds returned bytes even when the reported size is stale', () async {
    picker.result = FilePickerResult([
      PlatformFile(
        name: 'key',
        size: 1,
        bytes: Uint8List(maxPrivateKeyFileBytes + 1),
      ),
    ]);

    await expectLater(pickPrivateKeyText(), tooLarge());
  });

  test('rejects non-text bytes with the existing message', () async {
    picker.result = FilePickerResult([
      PlatformFile(name: 'key', size: 1, bytes: Uint8List.fromList([0xFF])),
    ]);

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

  test('both cancellation results return nothing', () async {
    expect(await pickPrivateKeyText(), isNull);
    picker.result = FilePickerResult([]);
    expect(await pickPrivateKeyText(), isNull);
  });
}
