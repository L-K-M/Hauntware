// CRED-05's recovery export file service: cancellation, the bounded read
// before a huge file is loaded, the owner-only desktop save, and the
// fixed file failures. The engine's export format lives in
// klabautermann_core's engine_recovery_test.dart.
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/services/recovery_files.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// A picked file with a scripted byte stream.
final class _FakeFile extends PlatformFile {
  _FakeFile({
    required this.name,
    Uint8List? bytes,
    this.stream,
    this.reportedLength,
    this.streamError,
    this.uriScheme = 'file',
  }) : bytes = bytes ?? Uint8List(0);

  @override
  final String name;

  final Uint8List bytes;
  final Stream<Uint8List>? stream;
  final int? reportedLength;
  final Object? streamError;
  final String uriScheme;

  int reads = 0;

  @override
  Uri get uri => Uri(scheme: uriScheme, path: '/picked/$name');

  @override
  Never get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => reportedLength;

  @override
  Future<int?> length() async => reportedLength ?? bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Stream<Uint8List> readAsByteStream() async* {
    reads++;
    final error = streamError;
    if (error != null) throw error;
    final source = stream;
    if (source != null) {
      yield* source;
      return;
    }
    if (bytes.isEmpty) return;
    final half = bytes.length ~/ 2;
    yield bytes.sublist(0, half);
    yield bytes.sublist(half);
  }
}

/// The platform save and open panels with scripted answers.
final class _FakePicker extends FilePickerPlatform {
  PlatformFile? picked;
  Uri? savedUri;
  Object? saveError;
  int saveCalls = 0;
  Uint8List? savedBytes;
  String? savedName;
  String? savedMimeType;
  List<String>? requestedExtensions;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    requestedExtensions = allowedExtensions;
    return picked;
  }

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saveCalls++;
    final error = saveError;
    if (error != null) throw error;
    final uri = savedUri;
    if (uri == null) return null;
    savedBytes = bytes;
    savedName = fileName;
    savedMimeType = mimeType;
    // The plugin writes before returning, as file_picker 13 does.
    if (uri.isScheme('file')) {
      await File(uri.toFilePath()).writeAsBytes(bytes, flush: true);
    }
    return uri;
  }
}

void main() {
  late _FakePicker picker;
  late PlatformRecoveryFiles files;
  String? suggestedName;

  setUp(() {
    picker = _FakePicker();
    suggestedName = null;
    files = PlatformRecoveryFiles(
      platform: picker,
      targetPlatform: TargetPlatform.macOS,
      desktopDestination: (name) async {
        suggestedName = name;
        return picker.savedUri?.toFilePath();
      },
    );
  });

  group('export file name', () {
    test('is product-prefixed and dated', () {
      expect(
        recoveryExportFileName(DateTime(2026, 11, 10)),
        'klabautermann-secrets-2026-11-10.json',
      );
      expect(
        recoveryExportFileName(DateTime(2026, 1, 2)),
        'klabautermann-secrets-2026-01-02.json',
      );
    });
  });

  group('save', () {
    test(
      'a cancelled panel writes nothing and reports no destination',
      () async {
        picker.savedUri = null;

        expect(
          await files.save(Uint8List.fromList([1]), 'export.json'),
          isNull,
        );
        expect(picker.savedBytes, isNull);
      },
    );

    test('a desktop file has one owner-only atomic writer', () async {
      final directory = await Directory.systemTemp.createTemp(
        'recovery-files-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = File('${directory.path}/export.json');
      picker.savedUri = Uri.file(destination.path);
      final bytes = Uint8List.fromList([1, 2, 3]);

      final saved = await files.save(bytes, 'export.json');

      expect(saved, destination.path);
      expect(suggestedName, 'export.json');
      expect(picker.saveCalls, 0);
      expect(destination.readAsBytesSync(), bytes);
      // 0600 in Unix mode bits; Windows keeps its per-user ACLs.
      if (Platform.isLinux || Platform.isMacOS) {
        expect(destination.statSync().mode & 0x1ff, 0x180);
      }
    });

    test('a failed atomic save leaves the old export untouched', () async {
      final directory = await Directory.systemTemp.createTemp(
        'recovery-files-preserve-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = File('${directory.path}/export.json');
      await destination.writeAsString('{"previous":true}');
      picker.savedUri = destination.uri;
      files = PlatformRecoveryFiles(
        platform: picker,
        targetPlatform: TargetPlatform.macOS,
        desktopDestination: (_) async => destination.path,
        writeExport: (_, _) async => throw const FileSystemException('refused'),
      );

      await expectLater(
        files.save(Uint8List.fromList('{"new":true}'.codeUnits), 'export.json'),
        throwsA(isA<RecoveryFileException>()),
      );
      expect(await destination.readAsString(), '{"previous":true}');
      expect(picker.saveCalls, 0);
    });

    test('a content uri is reported without a rewrite', () async {
      picker.savedUri = Uri(scheme: 'content', path: 'export');
      files = PlatformRecoveryFiles(
        platform: picker,
        targetPlatform: TargetPlatform.android,
        desktopDestination: (_) async => fail('A mobile save needs no path'),
      );

      expect(
        await files.save(Uint8List.fromList([1]), 'export.json'),
        'content:export',
      );
      expect(picker.saveCalls, 1);
      expect(picker.savedName, 'export.json');
      expect(picker.savedMimeType, 'application/json');
    });

    test('a write failure crosses as a fixed save failure', () async {
      final directory = await Directory.systemTemp.createTemp(
        'recovery-files-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final blocker = File('${directory.path}/blocker');
      await blocker.writeAsString('not a directory');
      // The parent is a file, so the atomic writer cannot create the
      // destination.
      picker.savedUri = Uri.file('${blocker.path}/export.json');

      await expectLater(
        files.save(Uint8List.fromList([1]), 'export.json'),
        throwsA(
          isA<RecoveryFileException>().having(
            (error) => error.failure,
            'failure',
            RecoveryFileFailure.saveFailed,
          ),
        ),
      );
    });
  });

  group('open', () {
    test('a cancelled panel reads nothing', () async {
      picker.picked = null;

      expect(await files.open(), isNull);
    });

    test('reads a picked file through its stream', () async {
      final bytes = Uint8List.fromList([123, 125]);
      picker.picked = _FakeFile(
        name: 'export.json',
        bytes: bytes,
        uriScheme: 'content',
      );

      expect(await files.open(), bytes);
      expect(picker.requestedExtensions, ['json']);
    });

    test('rejects oversized metadata without loading the contents', () async {
      final file = _FakeFile(
        name: 'too-large.json',
        reportedLength: SecretsExport.maxBytes + 1,
      );
      picker.picked = file;

      await expectLater(
        files.open(),
        throwsA(
          isA<RecoveryFileException>().having(
            (error) => error.failure,
            'failure',
            RecoveryFileFailure.tooLarge,
          ),
        ),
      );
      expect(file.reads, 0);
    });

    test('bounds a stream that runs past the export limit', () async {
      final file = _FakeFile(
        name: 'export.json',
        stream: Stream.value(Uint8List(SecretsExport.maxBytes + 1)),
      );
      picker.picked = file;

      await expectLater(
        files.open(),
        throwsA(
          isA<RecoveryFileException>().having(
            (error) => error.failure,
            'failure',
            RecoveryFileFailure.tooLarge,
          ),
        ),
      );
      expect(file.reads, 1);
    });

    test('an unreadable file crosses as a fixed unreadable failure', () async {
      picker.picked = _FakeFile(
        name: 'export.json',
        streamError: const FileSystemException('denied'),
      );

      await expectLater(
        files.open(),
        throwsA(
          isA<RecoveryFileException>().having(
            (error) => error.failure,
            'failure',
            RecoveryFileFailure.unreadable,
          ),
        ),
      );
    });
  });
}
